#!/usr/bin/env bash
#
# ssh_deploy.sh - the CI half of the Notable deploy.
#
# Runs on the GitHub Actions runner. It uploads a release tarball plus a fresh
# copy of remote_deploy.sh to the target VM, then invokes remote_deploy.sh over
# SSH. All the interesting logic lives in remote_deploy.sh, which is why that
# script is uploaded on every run rather than assumed to be present and current.
#
# Subcommands
#
#   activate                 upload a release and make it live
#   rollback [<release-id>]  re-point the VM at an earlier release
#
# Nothing about the target machine is baked in. Every value below comes from a
# GitHub Actions secret or repository variable; see docs/OPERATIONS.md for the
# full list and how to create them.
#
# Required environment
#
#   DEPLOY_SSH_HOST              hostname or IP of the VM
#   DEPLOY_SSH_USER              SSH login user
#   DEPLOY_SSH_KEY_FILE          path to the private key file the workflow wrote
#   DEPLOY_SSH_KNOWN_HOSTS_FILE  path to a known_hosts file pinning the VM's key
#   DEPLOY_ROOT                  release root on the VM, e.g. /opt/notable
#   DEPLOY_SYSTEMD_UNIT          e.g. notable.service
#   DEPLOY_DATABASE_PATH         SQLite path on the VM, outside DEPLOY_ROOT
#   DEPLOY_ENV_FILE              runtime env file on the VM, owned by the operator
#
# Required for activate
#
#   RELEASE_ID                   e.g. 20260730T101500Z-a1b2c3d
#   RELEASE_ARCHIVE              local path to the built release tarball
#
# Optional, forwarded to the VM when set
#
#   DEPLOY_SSH_PORT (default 22), DEPLOY_RELEASE_USER, DEPLOY_KEEP_RELEASES,
#   DEPLOY_PRIVILEGED_CMD, DEPLOY_HEALTH_RETRIES, DEPLOY_HEALTH_INTERVAL

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REMOTE_SCRIPT_SOURCE="$SCRIPT_DIR/remote_deploy.sh"
RELEASE_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'

note() { printf 'ssh-deploy: %s\n' "$*"; }
die() {
  printf 'ssh-deploy: error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
usage:
  ssh_deploy.sh activate
  ssh_deploy.sh rollback [<release-id>]
USAGE
}

require_env() {
  local name=$1
  local value=${!name:-}
  [ -n "$value" ] || die "$name is required but unset or empty"
}

# Quotes a value for the remote shell. The remote command is a single string
# handed to the login shell, so every interpolated value has to be quoted here
# or a path with a space silently becomes two arguments.
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

validate_release_id() {
  local id=$1
  [[ $id =~ $RELEASE_ID_PATTERN ]] ||
    die "invalid release id '$id': must match $RELEASE_ID_PATTERN"
}

load_config() {
  require_env DEPLOY_SSH_HOST
  require_env DEPLOY_SSH_USER
  require_env DEPLOY_SSH_KEY_FILE
  require_env DEPLOY_SSH_KNOWN_HOSTS_FILE
  require_env DEPLOY_ROOT
  require_env DEPLOY_SYSTEMD_UNIT
  require_env DEPLOY_DATABASE_PATH
  require_env DEPLOY_ENV_FILE

  [ -r "$DEPLOY_SSH_KEY_FILE" ] || die "SSH key file is not readable: $DEPLOY_SSH_KEY_FILE"
  [ -r "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] ||
    die "known_hosts file is not readable: $DEPLOY_SSH_KNOWN_HOSTS_FILE"
  [ -r "$REMOTE_SCRIPT_SOURCE" ] || die "cannot read $REMOTE_SCRIPT_SOURCE"

  SSH_PORT=${DEPLOY_SSH_PORT:-22}
  SSH_TARGET="$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST"
  REMOTE_SCRIPT="$DEPLOY_ROOT/bin/remote_deploy.sh"
  REMOTE_INCOMING="$DEPLOY_ROOT/incoming"

  # Host key verification stays on. A deploy that would happily talk to
  # whatever answers on that address is not a deploy worth automating.
  SSH_OPTS=(
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$DEPLOY_SSH_KNOWN_HOSTS_FILE"
    -i "$DEPLOY_SSH_KEY_FILE"
  )
}

remote_sh() {
  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" "$1"
}

upload() {
  local source=$1 destination=$2
  scp "${SSH_OPTS[@]}" -P "$SSH_PORT" "$source" "$SSH_TARGET:$destination"
}

# Builds the `KEY=value ...` prefix the remote script runs with. Optional
# settings are omitted rather than passed empty, so the remote script's own
# defaults still apply. DEPLOY_PRIVILEGED_CMD is the exception: it is a manual
# ssh_deploy-only knob (not an Actions variable), and set-but-empty must be
# distinguished from unset so an operator who clears the prefix still reaches
# the VM instead of silently falling back to `sudo -n`. Documented root mode
# is DEPLOY_SSH_USER=root with that default `sudo -n` prefix left in place.
remote_env_prefix() {
  local prefix="" name value
  local names=(
    DEPLOY_ROOT
    DEPLOY_SYSTEMD_UNIT
    DEPLOY_DATABASE_PATH
    DEPLOY_ENV_FILE
    DEPLOY_RELEASE_ID
    DEPLOY_RELEASE_ARCHIVE
    DEPLOY_RELEASE_USER
    DEPLOY_KEEP_RELEASES
    DEPLOY_PRIVILEGED_CMD
    DEPLOY_HEALTH_RETRIES
    DEPLOY_HEALTH_INTERVAL
  )

  for name in "${names[@]}"; do
    if [ "$name" = DEPLOY_PRIVILEGED_CMD ]; then
      if [ -n "${DEPLOY_PRIVILEGED_CMD+x}" ]; then
        prefix="$prefix$name=$(shquote "${DEPLOY_PRIVILEGED_CMD}") "
      fi
      continue
    fi
    value=${!name:-}
    [ -n "$value" ] || continue
    prefix="$prefix$name=$(shquote "$value") "
  done

  printf '%s' "$prefix"
}

push_remote_script() {
  remote_sh "mkdir -p $(shquote "$REMOTE_INCOMING") $(shquote "$DEPLOY_ROOT/bin")"
  upload "$REMOTE_SCRIPT_SOURCE" "$REMOTE_SCRIPT"
}

# `bash <script>` rather than executing it directly, so the deploy does not
# depend on scp having preserved the executable bit.
run_remote() {
  local prefix
  prefix=$(remote_env_prefix)

  local remote_command argument
  remote_command="$prefix bash $(shquote "$REMOTE_SCRIPT")"

  for argument in "$@"; do
    remote_command="$remote_command $(shquote "$argument")"
  done

  remote_sh "$remote_command"
}

cmd_activate() {
  require_env RELEASE_ID
  require_env RELEASE_ARCHIVE
  validate_release_id "$RELEASE_ID"

  [ -f "$RELEASE_ARCHIVE" ] || die "release archive not found: $RELEASE_ARCHIVE"

  local remote_archive="$REMOTE_INCOMING/$RELEASE_ID.tar.gz"

  push_remote_script
  note "uploading $RELEASE_ARCHIVE to $DEPLOY_SSH_HOST"
  upload "$RELEASE_ARCHIVE" "$remote_archive"

  note "activating $RELEASE_ID on $DEPLOY_SSH_HOST"
  # Read back indirectly by remote_env_prefix, which is why shellcheck cannot
  # see the use.
  # shellcheck disable=SC2034
  DEPLOY_RELEASE_ID=$RELEASE_ID
  # shellcheck disable=SC2034
  DEPLOY_RELEASE_ARCHIVE=$remote_archive
  run_remote activate
}

cmd_rollback() {
  local requested=${1:-}
  [ -z "$requested" ] || validate_release_id "$requested"

  push_remote_script

  if [ -n "$requested" ]; then
    note "rolling $DEPLOY_SSH_HOST back to $requested"
    run_remote rollback "$requested"
  else
    note "rolling $DEPLOY_SSH_HOST back to the previous release"
    run_remote rollback
  fi
}

main() {
  local subcommand=${1:-}
  [ $# -eq 0 ] || shift

  case "$subcommand" in
    activate | rollback) load_config ;;
    *)
      usage
      exit 64
      ;;
  esac

  case "$subcommand" in
    activate) cmd_activate "$@" ;;
    rollback) cmd_rollback "$@" ;;
  esac
}

main "$@"
