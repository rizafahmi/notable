#!/usr/bin/env bash
#
# remote_deploy.sh - activate, roll back, or inspect Notable releases on the
# deployment host.
#
# This script runs ON the VM. CI uploads it alongside a release tarball and
# invokes it over SSH (see scripts/deploy/ssh_deploy.sh). Nothing here knows
# anything about a specific machine: every host-specific value arrives as an
# environment variable, so the same script works for any operator's layout.
#
# Subcommands
#
#   activate     unpack a staged release, migrate, swap `current`, restart, prune
#   rollback     re-point `current` at an earlier release and restart
#   prune-plan   print, without deleting anything, what pruning would do and why
#
# Safety contract (mirrored in docs/OPERATIONS.md)
#
#   * The SQLite database at DEPLOY_DATABASE_PATH is never read, copied, moved,
#     truncated, or deleted here, and neither are its -wal/-shm companions.
#     Two independent guards enforce this as guarantees (neither needs the env
#     file): preflight refuses to mutate anything when the database resolves to
#     somewhere inside DEPLOY_ROOT, and the pruner separately refuses any
#     candidate whose path contains, or is contained by, the database or its
#     companions, re-checked immediately before every rm -rf.
#   * Pruning classifies each immediate child of releases/: release ids by the
#     retention policy (remove/keep), .staging-* crash leftovers as reclaim
#     unless they are this invocation's active staging directory or would touch
#     the database, and everything else as skip. protect never becomes remove
#     or reclaim. prune-plan prints that same classification without deleting.
#   * The runtime environment file at DEPLOY_ENV_FILE belongs to the operator.
#     This script hands its *path* to systemd. When the deploy user can read
#     that file, it also does one read-only lookup of the non-secret
#     DATABASE_PATH key and aborts on disagreement with DEPLOY_DATABASE_PATH.
#     Under the recommended permissions that read usually fails, so the
#     cross-check is opportunistic rather than a guarantee. The script never
#     writes, templates, or replaces that file, and never loads the secrets
#     into its own process environment.
#   * Migrations run from the *new* release's own bin/migrate, before `current`
#     moves. A failed migration therefore leaves the running release exactly
#     where it was.
#   * Rollback never runs migrations. Reversing a schema change is a deliberate
#     manual act, not a side effect of re-pointing a symlink.
#
# Required environment (all subcommands)
#
#   DEPLOY_ROOT            e.g. /opt/notable
#   DEPLOY_DATABASE_PATH   e.g. /var/lib/notable/notable.db (must be OUTSIDE DEPLOY_ROOT)
#
# Required for activate and rollback
#
#   DEPLOY_SYSTEMD_UNIT    e.g. notable.service
#   DEPLOY_ENV_FILE        e.g. /etc/notable/notable.env
#
# Required for activate
#
#   DEPLOY_RELEASE_ID      e.g. 20260730T101500Z-a1b2c3d
#   DEPLOY_RELEASE_ARCHIVE path to the uploaded release tarball
#
# Optional
#
#   DEPLOY_RELEASE_USER      chown the unpacked release to this user, and run
#                            migrations as them
#   DEPLOY_KEEP_RELEASES     how many releases to retain (default 5, minimum 2)
#   DEPLOY_HEALTH_RETRIES    is-active polls after restart (default 15)
#   DEPLOY_HEALTH_INTERVAL   seconds between polls (default 2)
#   DEPLOY_PRIVILEGED_CMD    prefix for systemctl/systemd-run/chown/rm
#                            (default "sudo -n"; set to "" to run with no prefix)

set -euo pipefail

# Rollback picks the newest release name that sorts below the current one, and
# pruning ranks names the same way. Both have to agree with `sort`, so collation
# is pinned to bytes rather than left to whatever locale the SSH session brings.
export LC_ALL=C

RELEASE_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'

note() { printf 'deploy: %s\n' "$*"; }
warn() { printf 'deploy: %s\n' "$*" >&2; }
die() {
  printf 'deploy: error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
usage:
  remote_deploy.sh activate
  remote_deploy.sh rollback [<release-id>]
  remote_deploy.sh prune-plan
USAGE
}

require_env() {
  local name=$1
  local value=${!name:-}
  [ -n "$value" ] || die "$name is required but unset or empty"
}

# Resolves a path to its physical location without requiring it to exist.
# `realpath -m` and `readlink -f` are not portable across GNU and BSD
# userlands, and the deploy has to behave identically on both.
# When the final component exists and is a symlink, follow it with a bounded
# readlink loop so a DEPLOY_DATABASE_PATH symlink into a release directory
# cannot defeat the database guards.
abs_path() {
  local path=$1 dir base depth=0 target
  local max_depth=32

  dir=$(dirname -- "$path")
  base=$(basename -- "$path")

  if [ -d "$dir" ]; then
    path="$(cd -- "$dir" && pwd -P)/$base"
  fi

  while [ -L "$path" ] && [ "$depth" -lt "$max_depth" ]; do
    target=$(readlink "$path") || break
    case "$target" in
      /*) path=$target ;;
      *) path="$(dirname -- "$path")/$target" ;;
    esac
    dir=$(dirname -- "$path")
    base=$(basename -- "$path")
    if [ -d "$dir" ]; then
      path="$(cd -- "$dir" && pwd -P)/$base"
    fi
    depth=$((depth + 1))
  done

  printf '%s\n' "$path"
}

# True when $2 is $1 itself or lives underneath it.
path_contains() {
  local parent=${1%/} child=$2
  [ "$child" = "$parent" ] || case "$child" in "$parent"/*) return 0 ;; esac
  [ "$child" = "$parent" ]
}

run_privileged() {
  if [ "${#PRIVILEGED[@]}" -gt 0 ]; then
    "${PRIVILEGED[@]}" "$@"
  else
    "$@"
  fi
}

# Single-key, read-only lookup against the operator's env file. Nothing else is
# read out of it and nothing is ever written back.
env_file_database_path() {
  local line
  [ -n "$ENV_FILE" ] && [ -r "$ENV_FILE" ] || return 1

  line=$(grep -E '^[[:space:]]*DATABASE_PATH[[:space:]]*=' "$ENV_FILE" | tail -n 1) || return 1
  [ -n "$line" ] || return 1

  line=${line#*=}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  line=${line%\"}
  line=${line#\"}
  line=${line%\'}
  line=${line#\'}

  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

load_common_config() {
  require_env DEPLOY_ROOT
  require_env DEPLOY_DATABASE_PATH

  [ -d "$DEPLOY_ROOT" ] || die "DEPLOY_ROOT does not exist: $DEPLOY_ROOT"

  DEPLOY_ROOT_ABS=$(abs_path "$DEPLOY_ROOT")
  RELEASES_DIR="$DEPLOY_ROOT_ABS/releases"
  CURRENT_LINK="$DEPLOY_ROOT_ABS/current"
  mkdir -p "$RELEASES_DIR"

  ENV_FILE=${DEPLOY_ENV_FILE:-}
  KEEP_RELEASES=${DEPLOY_KEEP_RELEASES:-5}

  case "$KEEP_RELEASES" in
    '' | *[!0-9]*) die "DEPLOY_KEEP_RELEASES must be an integer, got: $KEEP_RELEASES" ;;
  esac

  # Retaining fewer than two releases would delete the only thing rollback
  # could ever point at, which defeats the entire layout.
  [ "$KEEP_RELEASES" -ge 2 ] ||
    die "DEPLOY_KEEP_RELEASES must be at least 2 so a rollback target always survives"

  DATABASE_ABS=$(abs_path "$DEPLOY_DATABASE_PATH")
  GUARDED_PATHS=("$DATABASE_ABS" "$DATABASE_ABS-wal" "$DATABASE_ABS-shm")

  local declared declared_abs
  if declared=$(env_file_database_path); then
    declared_abs=$(abs_path "$declared")
    [ "$declared_abs" = "$DATABASE_ABS" ] || die \
      "DATABASE_PATH mismatch: DEPLOY_DATABASE_PATH is $DATABASE_ABS but $ENV_FILE declares $declared_abs. Refusing to act with an unverified database location."
  else
    warn "could not read DATABASE_PATH from ${ENV_FILE:-<unset>}; relying on DEPLOY_DATABASE_PATH alone"
  fi

  PRIVILEGED=()
  local privileged_spec=${DEPLOY_PRIVILEGED_CMD-sudo -n}
  if [ -n "$privileged_spec" ]; then
    # shellcheck disable=SC2206 # deliberate word splitting: this is a command prefix
    PRIVILEGED=($privileged_spec)
  fi
}

# Only the mutating subcommands refuse outright. `prune-plan` is a read-only
# diagnostic, and an operator staring at a misplaced database is better served
# by an explanation than by a bare refusal.
assert_database_outside_deploy_root() {
  local guarded
  for guarded in "${GUARDED_PATHS[@]}"; do
    if path_contains "$DEPLOY_ROOT_ABS" "$guarded"; then
      die "refusing to deploy: the database path $guarded is inside DEPLOY_ROOT ($DEPLOY_ROOT_ABS). Move the database onto its own path outside the deploy root first."
    fi
  done
}

load_service_config() {
  require_env DEPLOY_SYSTEMD_UNIT
  require_env DEPLOY_ENV_FILE

  UNIT=$DEPLOY_SYSTEMD_UNIT
  RELEASE_USER=${DEPLOY_RELEASE_USER:-}
  HEALTH_RETRIES=${DEPLOY_HEALTH_RETRIES:-15}
  HEALTH_INTERVAL=${DEPLOY_HEALTH_INTERVAL:-2}
}

validate_release_id() {
  local id=$1
  [[ $id =~ $RELEASE_ID_PATTERN ]] ||
    die "invalid release id '$id': must match $RELEASE_ID_PATTERN"
}

current_release_id() {
  local target
  target=$(readlink "$CURRENT_LINK" 2>/dev/null) || return 1
  [ -n "$target" ] || return 1
  basename "$target"
}

# Release ids are minted as <UTC timestamp>-<short sha>, so a reverse
# lexicographic sort is a reverse chronological sort. Only real release
# directories are emitted: crash leftovers like .staging-<id>.<pid> must never
# enter rollback selection or the retention keep_list.
release_ids_desc() {
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null |
    while IFS= read -r entry; do
      [ -L "$entry" ] && continue
      [ -d "$entry" ] || continue
      name=$(basename "$entry")
      [[ $name =~ $RELEASE_ID_PATTERN ]] || continue
      printf '%s\n' "$name"
    done |
    sort -r
}

# The rollback target is the newest release strictly older than the current
# one. Picking "the newest release that is not current" instead would
# ping-pong between the last two releases on a second rollback.
rollback_target_id() {
  local current=$1 candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [[ "$candidate" < "$current" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(release_ids_desc)
  return 1
}

touches_database() {
  local candidate=$1 guarded
  for guarded in "${GUARDED_PATHS[@]}"; do
    if path_contains "$candidate" "$guarded" || path_contains "$guarded" "$candidate"; then
      return 0
    fi
  done
  return 1
}

# Emits one verdict line per entry in the releases directory:
#
#   remove  <path>
#   reclaim <path> staging-orphan
#   keep    <path> <reason>
#   protect <path> contains-database
#   skip    <path> <reason>
#
# Both `prune-plan` and the destructive prune consume this exact output, so the
# plan an operator inspects is by construction the plan that would run.
# `reclaim` is reserved for crash leftovers (.staging-*), distinct from
# `remove` of an expired real release.
classify_releases() {
  local current retained keep_list=() entry name

  current=$(current_release_id 2>/dev/null || true)

  retained=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$retained" -lt "$KEEP_RELEASES" ]; then
      keep_list+=("$name")
      retained=$((retained + 1))
    fi
  done < <(release_ids_desc)

  # The running release and the release it would roll back to are retained
  # regardless of age, so a rollback after several deploys still has a target.
  if [ -n "$current" ]; then
    keep_list+=("$current")
    local previous
    if previous=$(rollback_target_id "$current"); then
      keep_list+=("$previous")
    fi
  fi

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name=$(basename "$entry")

    if [ -L "$entry" ]; then
      printf 'skip %s symlink\n' "$entry"
      continue
    fi

    if [ -d "$entry" ] && [[ $name == .staging-* ]]; then
      if [ -n "${ACTIVE_STAGING:-}" ] && [ "$entry" = "$ACTIVE_STAGING" ]; then
        printf 'skip %s active-staging\n' "$entry"
        continue
      fi
      if [ -n "$current" ] && [ "$name" = "$current" ]; then
        printf 'keep %s retained\n' "$entry"
        continue
      fi
      if touches_database "$(abs_path "$entry")"; then
        printf 'protect %s contains-database\n' "$entry"
        continue
      fi
      printf 'reclaim %s staging-orphan\n' "$entry"
      continue
    fi

    if [ ! -d "$entry" ] || ! [[ $name =~ $RELEASE_ID_PATTERN ]]; then
      printf 'skip %s not-a-release-directory\n' "$entry"
      continue
    fi

    if touches_database "$(abs_path "$entry")"; then
      printf 'protect %s contains-database\n' "$entry"
      continue
    fi

    local kept=no candidate
    for candidate in ${keep_list[@]+"${keep_list[@]}"}; do
      if [ "$candidate" = "$name" ]; then
        kept=yes
        break
      fi
    done

    if [ "$kept" = yes ]; then
      printf 'keep %s retained\n' "$entry"
    else
      printf 'remove %s\n' "$entry"
    fi
  done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sort)
}

prune_releases() {
  local verdict path

  while IFS= read -r verdict; do
    case "$verdict" in
      "remove "*)
        path=${verdict#remove }
        # Re-assert every guard immediately before the rm. classify_releases
        # already checked them; a second check here means a future refactor of
        # the classifier cannot quietly widen what gets deleted.
        remove_release_directory "$path" "pruning old release $(basename "$path")"
        ;;
      "reclaim "*)
        path=${verdict#reclaim }
        path=${path% staging-orphan}
        remove_release_directory "$path" "removing staging leftover $(basename "$path")"
        ;;
      "skip "*) note "$verdict" ;;
      "protect "*) warn "$verdict" ;;
    esac
  done < <(classify_releases)
}

# Shared pre-rm gate for every release-directory deletion. When RELEASE_USER is
# set, activate chowns those directories so the deploy user cannot unlink their
# contents; only the rm itself then goes through run_privileged.
remove_release_directory() {
  local path=$1
  local message=${2:-}

  [ "$(dirname "$path")" = "$RELEASES_DIR" ] || die "refusing to remove $path: outside $RELEASES_DIR"
  [ ! -L "$path" ] || die "refusing to remove $path: symlink"
  [ -d "$path" ] || die "refusing to remove $path: not a directory"
  ! touches_database "$(abs_path "$path")" || die "refusing to remove $path: it contains the database"

  [ -z "$message" ] || note "$message"

  if [ -n "${RELEASE_USER:-}" ]; then
    run_privileged rm -rf "$path"
  else
    rm -rf "$path"
  fi
}

# rename(2) is atomic, so a concurrent reader of `current` sees either the old
# release or the new one, never a missing symlink. `mv` needs an explicit "do
# not follow the destination symlink" flag to get there: GNU coreutils spells
# it -T, BSD/macOS spells it -h.
swap_current() {
  local target=$1
  local tmp="$DEPLOY_ROOT_ABS/.current.swap.$$"

  rm -f "$tmp"
  ln -s "$target" "$tmp"

  if ! mv -T "$tmp" "$CURRENT_LINK" 2>/dev/null && ! mv -h "$tmp" "$CURRENT_LINK" 2>/dev/null; then
    rm -f "$tmp"
    die "could not atomically swap $CURRENT_LINK to $target"
  fi

  [ "$(readlink "$CURRENT_LINK")" = "$target" ] ||
    die "$CURRENT_LINK does not point at $target after the swap"
}

restart_unit() {
  note "restarting $UNIT"
  run_privileged systemctl restart "$UNIT"
}

unit_became_active() {
  local attempt=0
  while [ "$attempt" -lt "$HEALTH_RETRIES" ]; do
    if run_privileged systemctl is-active --quiet "$UNIT"; then
      return 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -ge "$HEALTH_RETRIES" ] || sleep "$HEALTH_INTERVAL"
  done
  return 1
}

activate_release() {
  local release_id=$1
  swap_current "$RELEASES_DIR/$release_id"
  restart_unit
}

cmd_activate() {
  load_service_config
  assert_database_outside_deploy_root

  require_env DEPLOY_RELEASE_ID
  require_env DEPLOY_RELEASE_ARCHIVE

  local release_id=$DEPLOY_RELEASE_ID
  local archive=$DEPLOY_RELEASE_ARCHIVE
  validate_release_id "$release_id"

  local release_dir="$RELEASES_DIR/$release_id"
  [ ! -e "$release_dir" ] || die "release directory already exists: $release_dir"
  [ -f "$archive" ] || die "release archive not found: $archive"

  ACTIVATE_CREATED_RELEASE=
  local staging="$RELEASES_DIR/.staging-$release_id.$$"
  # Defensive: prune_releases runs later in this same invocation and must never
  # select the staging tree this activate still owns (no-op after a successful mv).
  ACTIVE_STAGING=$staging
  # shellcheck disable=SC2064 # expand ids now; cleanup must see this attempt's values
  trap "activate_failure_cleanup $(printf '%q' "$release_id") $(printf '%q' "$archive") $(printf '%q' "$staging")" EXIT

  mkdir "$staging"
  note "unpacking $release_id"

  tar -xzf "$archive" -C "$staging" ||
    die "could not unpack $archive"

  if [ ! -x "$staging/bin/migrate" ] || [ ! -x "$staging/bin/server" ]; then
    die "archive does not look like a Notable release: bin/migrate and bin/server are missing"
  fi

  mv "$staging" "$release_dir"
  ACTIVE_STAGING=
  ACTIVATE_CREATED_RELEASE=$release_id

  if [ -n "$RELEASE_USER" ]; then
    run_privileged chown -R "$RELEASE_USER" "$release_dir"
  fi

  run_migrations "$release_id" "$release_dir"

  local previous
  previous=$(current_release_id 2>/dev/null || true)

  activate_release "$release_id"

  if ! unit_became_active; then
    handle_failed_start "$release_id" "$previous"
  fi

  note "$release_id is live"
  prune_releases
  trap - EXIT
  discard_upload "$archive"
}

# On a failed activate, clear the staged upload, any leftover staging tree, and
# any never-activated release directory so repeated failures cannot fill a small
# disk. Success clears the trap above and discards the upload itself.
activate_failure_cleanup() {
  local release_id=$1 archive=$2 staging=${3:-}
  trap - EXIT
  discard_upload "$archive"
  discard_staging_dir "$staging"
  if [ "${ACTIVATE_CREATED_RELEASE:-}" = "$release_id" ]; then
    discard_never_activated_release "$release_id"
  fi
}

# Clears the uploaded tarball, but only when it is genuinely an upload sitting
# in the staging directory this script owns. DEPLOY_RELEASE_ARCHIVE is operator
# supplied, and someone deploying a local tarball by hand should not have their
# source file eaten -- let alone anything else they happened to point it at.
discard_upload() {
  local archive=$1
  local archive_abs
  archive_abs=$(abs_path "$archive")

  if [ "$(dirname "$archive_abs")" != "$DEPLOY_ROOT_ABS/incoming" ]; then
    note "leaving $archive in place: it is not an upload under $DEPLOY_ROOT_ABS/incoming"
    return 0
  fi

  ! touches_database "$archive_abs" || die "refusing to remove $archive: it is the database"

  rm -f "$archive_abs"
}

# Removes a leftover .staging-* tree from a failed unpack. No-op after a
# successful mv into the final release directory. Uses the same pre-rm checks
# as the pruner.
discard_staging_dir() {
  local path=$1
  local name current

  [ -n "$path" ] || return 0
  [ -e "$path" ] || return 0

  name=$(basename -- "$path")
  current=$(current_release_id 2>/dev/null || true)
  if [ "$name" = "$current" ]; then
    note "leaving $path in place: it is the current release"
    return 0
  fi

  remove_release_directory "$path" "removing leftover staging directory $name"
}

# Removes a release directory created by this activate attempt that never became
# (or no longer is) current. Uses the same pre-rm checks as the pruner.
discard_never_activated_release() {
  local release_id=$1
  local path=$RELEASES_DIR/$release_id
  local current

  [ -n "$release_id" ] || return 0
  [ -e "$path" ] || return 0

  current=$(current_release_id 2>/dev/null || true)
  if [ "$release_id" = "$current" ]; then
    note "leaving $path in place: it is the current release"
    return 0
  fi

  remove_release_directory "$path" "removing never-activated release $release_id"
}

# Migrations run through systemd rather than through this script so that the
# environment file is applied by systemd itself, exactly as it is for the
# service. The secrets in it never enter this script's process.
run_migrations() {
  local release_id=$1 release_dir=$2
  local args=(
    --wait
    --collect
    --pipe
    --unit "${UNIT%.service}-migrate-$release_id"
    --property "EnvironmentFile=$ENV_FILE"
    --property "WorkingDirectory=$release_dir"
  )

  [ -z "$RELEASE_USER" ] || args+=(--property "User=$RELEASE_USER")

  note "running migrations from $release_dir/bin/migrate"
  run_privileged systemd-run "${args[@]}" -- "$release_dir/bin/migrate" ||
    die "migration failed for $release_id; $CURRENT_LINK was left untouched"
}

handle_failed_start() {
  local release_id=$1 previous=$2

  warn "$UNIT did not become active after deploying $release_id"

  if [ -z "$previous" ] || [ ! -d "$RELEASES_DIR/$previous" ]; then
    die "$UNIT is down and there is no previous release to fall back to; the service needs manual attention"
  fi

  activate_release "$previous"

  if unit_became_active; then
    die "deploy of $release_id failed to start and was rolled back to $previous"
  fi

  die "deploy of $release_id failed to start, and $previous did not come up either; the service needs manual attention"
}

cmd_rollback() {
  load_service_config
  assert_database_outside_deploy_root

  local requested=${1:-} current target

  current=$(current_release_id) || die "$CURRENT_LINK is missing; nothing to roll back from"

  if [ -n "$requested" ]; then
    validate_release_id "$requested"

    if [ ! -d "$RELEASES_DIR/$requested" ] || [ -L "$RELEASES_DIR/$requested" ]; then
      die "no such release: $requested"
    fi

    target=$requested
  else
    target=$(rollback_target_id "$current") ||
      die "no earlier release than $current is retained; nothing to roll back to"
  fi

  [ "$target" != "$current" ] || die "$target is already the current release"

  note "rolling back from $current to $target"
  activate_release "$target"

  unit_became_active ||
    die "$UNIT did not become active after rolling back to $target; the service needs manual attention"

  note "$target is live"
}

cmd_prune_plan() {
  note "retention bound: $KEEP_RELEASES releases, plus the current release and its rollback target"
  note "protected database paths: ${GUARDED_PATHS[*]}"
  classify_releases
}

main() {
  local subcommand=${1:-}
  [ $# -eq 0 ] || shift

  case "$subcommand" in
    activate)
      load_common_config
      cmd_activate "$@"
      ;;
    rollback)
      load_common_config
      cmd_rollback "$@"
      ;;
    prune-plan)
      load_common_config
      cmd_prune_plan "$@"
      ;;
    *)
      usage
      exit 64
      ;;
  esac
}

main "$@"
