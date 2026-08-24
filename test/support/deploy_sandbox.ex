defmodule Notable.DeploySandbox do
  @moduledoc """
  A throwaway filesystem plus stubbed privileged tooling for exercising
  `scripts/deploy/remote_deploy.sh` without ever touching a real VM.

  The deploy path is the one piece of this repo that can take the live payment
  box down, and it can never be rehearsed against the real host. So it is
  rehearsed here instead. The sandbox builds a deploy root, fake release
  tarballs, and `sudo`/`systemctl`/`systemd-run`/`chown` stubs that all append
  to one ordered log file.

  The stubs record the `current` symlink target at the moment they run, which
  is what makes *ordering* assertable rather than merely "each step happened":
  a migrate line carrying the old target proves migrations ran before the swap,
  and a restart line carrying the new target proves the swap preceded it.
  """

  @script Path.expand("../../scripts/deploy/remote_deploy.sh", __DIR__)
  @ssh_script Path.expand("../../scripts/deploy/ssh_deploy.sh", __DIR__)

  @typedoc "Absolute paths and handles for one sandboxed deploy target."
  @type t :: %{
          root: String.t(),
          deploy_root: String.t(),
          releases_dir: String.t(),
          current: String.t(),
          incoming_dir: String.t(),
          database_path: String.t(),
          env_file: String.t(),
          log: String.t(),
          bin: String.t(),
          unit: String.t()
        }

  @doc "The script under test."
  @spec script() :: String.t()
  def script, do: @script

  @doc """
  Builds a sandbox whose database deliberately lives *outside* the deploy root,
  mirroring the layout `docs/OPERATIONS.md` prescribes.

  Options:

    * `:database_path` - override the database location, used by the tests that
      check the guards fire when it is somewhere it must never be.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    root = make_tmp_dir()
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    deploy_root = Path.join(root, "opt/notable")

    database_path =
      Keyword.get_lazy(opts, :database_path, fn ->
        Path.join(root, "var/lib/notable/notable.db")
      end)

    sandbox = %{
      root: root,
      deploy_root: deploy_root,
      releases_dir: Path.join(deploy_root, "releases"),
      current: Path.join(deploy_root, "current"),
      incoming_dir: Path.join(deploy_root, "incoming"),
      database_path: database_path,
      env_file: Path.join(root, "etc/notable/notable.env"),
      log: Path.join(root, "invocations.log"),
      bin: Path.join(root, "stub-bin"),
      unit: "notable.service"
    }

    File.mkdir_p!(sandbox.releases_dir)
    File.mkdir_p!(sandbox.incoming_dir)
    File.mkdir_p!(sandbox.bin)
    File.write!(sandbox.log, "")

    write_database(sandbox)
    write_env_file(sandbox, database_path)
    write_stubs(sandbox)

    sandbox
  end

  @doc """
  Writes a fake release tarball into the sandbox's incoming directory.

  The tarball carries a `bin/migrate` that logs the `current` symlink target it
  observed, so migration ordering is provable from the log alone.
  """
  @spec stage_release(t(), String.t()) :: String.t()
  def stage_release(sandbox, release_id) do
    build_dir = Path.join([sandbox.root, "build", release_id])
    bin_dir = Path.join(build_dir, "bin")
    File.mkdir_p!(bin_dir)

    write_executable(Path.join(bin_dir, "migrate"), """
    #!/bin/sh
    #{stub_preamble()}
    printf 'migrate id=%s current=%s\\n' "#{release_id}" "$(current_target)" >> "$DEPLOY_SANDBOX_LOG"
    if [ -f "$DEPLOY_SANDBOX_DIR/fail-migrate" ]; then
      echo "boom" >&2
      exit 1
    fi
    exit 0
    """)

    write_executable(Path.join(bin_dir, "server"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(build_dir, "RELEASE_MARKER"), release_id)

    archive = Path.join(sandbox.incoming_dir, "#{release_id}.tar.gz")
    {_out, 0} = System.cmd("tar", ["-czf", archive, "-C", build_dir, "."], stderr_to_stdout: true)
    archive
  end

  @doc """
  Stages and activates `release_id`, returning `{output, exit_status}`.

  Extra environment entries are merged last so a test can override any default.
  """
  @spec activate(t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def activate(sandbox, release_id, extra_env \\ []) do
    archive = stage_release(sandbox, release_id)

    defaults = [DEPLOY_RELEASE_ID: release_id, DEPLOY_RELEASE_ARCHIVE: archive]
    run(sandbox, ["activate"], Keyword.merge(defaults, extra_env))
  end

  @doc "Runs the rollback subcommand, optionally with an explicit release id."
  @spec rollback(t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def rollback(sandbox, args \\ [], extra_env \\ []) do
    run(sandbox, ["rollback" | args], extra_env)
  end

  @doc """
  Runs the read-only `prune-plan` subcommand and returns its verdict lines.

  This is the same classification the destructive prune uses, which is what
  makes it worth asserting against.
  """
  @spec prune_plan(t(), keyword()) :: [String.t()]
  def prune_plan(sandbox, extra_env \\ []) do
    {output, 0} = run(sandbox, ["prune-plan"], extra_env)

    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 =~ ~r/^(remove|reclaim|keep|protect|skip) /))
  end

  @doc """
  Creates release directories directly, without running a deploy.

  Retention rules depend on how many releases exist and which one is current,
  and building those states through real activations would obscure the very
  thing under test.
  """
  @spec seed_releases(t(), [String.t()], String.t()) :: :ok
  def seed_releases(sandbox, release_ids, current_id) do
    Enum.each(release_ids, fn id ->
      File.mkdir_p!(Path.join([sandbox.releases_dir, id, "bin"]))
    end)

    File.rm(sandbox.current)
    File.ln_s!(Path.join(sandbox.releases_dir, current_id), sandbox.current)
  end

  @doc """
  Rewrites the `DATABASE_PATH` line in the sandbox's runtime env file.

  The deploy cross-checks that key against `DEPLOY_DATABASE_PATH`, so tests
  that relocate the database have to relocate both.
  """
  @spec put_env_database_path(t(), String.t()) :: :ok
  def put_env_database_path(sandbox, path) do
    write_env_file(sandbox, path)
  end

  @doc "Runs the script with the sandbox environment applied."
  @spec run(t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(sandbox, args, extra_env \\ []) do
    env =
      sandbox
      |> base_env()
      |> Keyword.merge(extra_env)
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)

    cmd_with_env(@script, args, env)
  end

  @doc """
  Runs `scripts/deploy/ssh_deploy.sh` with `ssh`/`scp` stubbed out.

  The CI half of the deploy is worth testing on its own: it composes the SSH
  invocation and decides what is uploaded where, and getting either wrong is
  how a deploy reaches the wrong machine.
  """
  @spec ssh_deploy(t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def ssh_deploy(sandbox, args, extra_env \\ []) do
    env =
      sandbox
      |> base_env()
      |> Keyword.merge(ssh_env(sandbox))
      |> Keyword.merge(extra_env)
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)

    cmd_with_env(@ssh_script, args, env)
  end

  # `System.cmd`'s `:env` option treats `""` as "unset this variable", but
  # deploy scripts need set-but-empty values (notably `DEPLOY_PRIVILEGED_CMD=`
  # for root mode). Export those through bash so the child sees them as set.
  defp cmd_with_env(script, args, env) do
    {empty, rest} = Enum.split_with(env, fn {_key, value} -> value == "" end)

    case empty do
      [] ->
        System.cmd(script, args, env: rest, stderr_to_stdout: true)

      _ ->
        exports = Enum.map_join(empty, " ", fn {key, _} -> "#{key}=" end)

        System.cmd(
          "bash",
          ["-c", "#{exports} exec \"$1\" \"${@:2}\"", "bash", script | args],
          env: rest,
          stderr_to_stdout: true
        )
    end
  end

  @doc "A local stand-in for the release tarball CI hands to `ssh_deploy.sh`."
  @spec build_artifact(t(), String.t()) :: String.t()
  def build_artifact(sandbox, release_id) do
    path = Path.join(sandbox.root, "#{release_id}.tar.gz")
    File.write!(path, "pretend release tarball")
    path
  end

  @doc "The private key file the SSH stubs are pointed at, plus its contents."
  @spec ssh_key(t()) :: {String.t(), String.t()}
  def ssh_key(sandbox) do
    {Path.join(sandbox.root, "deploy_key"), "-----BEGIN PRIVATE KEY-----\nsupersecret\n"}
  end

  @doc "The ordered list of stub invocations recorded so far."
  @spec log(t()) :: [String.t()]
  def log(sandbox) do
    sandbox.log |> File.read!() |> String.split("\n", trim: true)
  end

  @doc "The release id `current` points at, or `nil` when the symlink is absent."
  @spec current_release(t()) :: String.t() | nil
  def current_release(sandbox) do
    case File.read_link(sandbox.current) do
      {:ok, target} -> Path.basename(target)
      {:error, _reason} -> nil
    end
  end

  @doc "Release directory names present on the box, oldest first."
  @spec releases(t()) :: [String.t()]
  def releases(sandbox) do
    sandbox.releases_dir |> File.ls!() |> Enum.sort()
  end

  @doc "Makes `systemctl is-active` report failure whenever `current` is `release_id`."
  @spec break_unit_for(t(), String.t()) :: :ok
  def break_unit_for(sandbox, release_id) do
    File.write!(Path.join(sandbox.root, "broken-release"), release_id)
  end

  @doc "Makes the staged release's `bin/migrate` exit non-zero."
  @spec break_migrations(t()) :: :ok
  def break_migrations(sandbox) do
    File.write!(Path.join(sandbox.root, "fail-migrate"), "")
  end

  @doc "A fingerprint of the database trio, for asserting nothing touched them."
  @spec database_fingerprint(t()) :: [{String.t(), String.t() | :missing}]
  def database_fingerprint(sandbox) do
    Enum.map(database_files(sandbox), fn path ->
      case File.read(path) do
        {:ok, contents} -> {Path.basename(path), contents}
        {:error, _reason} -> {Path.basename(path), :missing}
      end
    end)
  end

  @doc "The database file plus its WAL companions."
  @spec database_files(t()) :: [String.t()]
  def database_files(sandbox) do
    [sandbox.database_path, sandbox.database_path <> "-wal", sandbox.database_path <> "-shm"]
  end

  @doc "Contents and mtime of the runtime env file, for asserting it is never written."
  @spec env_file_fingerprint(t()) :: {String.t(), term()}
  def env_file_fingerprint(sandbox) do
    {File.read!(sandbox.env_file), File.stat!(sandbox.env_file, time: :posix).mtime}
  end

  defp base_env(sandbox) do
    [
      PATH: sandbox.bin <> ":" <> System.get_env("PATH", ""),
      DEPLOY_ROOT: sandbox.deploy_root,
      DEPLOY_SYSTEMD_UNIT: sandbox.unit,
      DEPLOY_DATABASE_PATH: sandbox.database_path,
      DEPLOY_ENV_FILE: sandbox.env_file,
      DEPLOY_KEEP_RELEASES: "3",
      DEPLOY_HEALTH_RETRIES: "1",
      DEPLOY_HEALTH_INTERVAL: "0",
      DEPLOY_SANDBOX_LOG: sandbox.log,
      DEPLOY_SANDBOX_DIR: sandbox.root
    ]
  end

  defp ssh_env(sandbox) do
    {key_path, key_material} = ssh_key(sandbox)
    File.write!(key_path, key_material)
    File.chmod!(key_path, 0o600)

    known_hosts = Path.join(sandbox.root, "known_hosts")
    File.write!(known_hosts, "deploy.example.test ssh-ed25519 AAAA\n")

    [
      DEPLOY_SSH_HOST: "deploy.example.test",
      DEPLOY_SSH_USER: "deployer",
      DEPLOY_SSH_PORT: "2222",
      DEPLOY_SSH_KEY_FILE: key_path,
      DEPLOY_SSH_KNOWN_HOSTS_FILE: known_hosts
    ]
  end

  defp write_database(sandbox) do
    sandbox.database_path |> Path.dirname() |> File.mkdir_p!()

    sandbox
    |> database_files()
    |> Enum.each(fn path -> File.write!(path, "precious #{Path.basename(path)}") end)
  end

  defp write_env_file(sandbox, database_path) do
    sandbox.env_file |> Path.dirname() |> File.mkdir_p!()

    File.write!(sandbox.env_file, """
    PHX_SERVER=true
    DATABASE_PATH=#{database_path}
    SECRET_KEY_BASE=sandbox_secret_key_base
    """)
  end

  # `current_target` is shared by every stub so the log lines are comparable.
  defp stub_preamble do
    """
    current_target() {
      if [ -L "$DEPLOY_ROOT/current" ]; then
        basename "$(readlink "$DEPLOY_ROOT/current")"
      else
        printf 'none'
      fi
    }
    """
  end

  defp write_stubs(sandbox) do
    # `sudo` strips its own flags and execs the rest, so the privileged prefix
    # is exercised for real rather than short-circuited.
    write_executable(Path.join(sandbox.bin, "sudo"), """
    #!/bin/sh
    printf 'sudo %s\\n' "$*" >> "$DEPLOY_SANDBOX_LOG"
    while [ $# -gt 0 ]; do
      case "$1" in
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    exec "$@"
    """)

    write_executable(Path.join(sandbox.bin, "systemctl"), """
    #!/bin/sh
    #{stub_preamble()}
    printf 'systemctl %s current=%s\\n' "$*" "$(current_target)" >> "$DEPLOY_SANDBOX_LOG"
    if [ "$1" = "is-active" ]; then
      broken_file="$DEPLOY_SANDBOX_DIR/broken-release"
      if [ -f "$broken_file" ] && [ "$(cat "$broken_file")" = "$(current_target)" ]; then
        echo failed
        exit 3
      fi
      echo active
    fi
    exit 0
    """)

    # `systemd-run` logs the full invocation then execs whatever follows the
    # bare `--`, so the release's own bin/migrate really runs.
    write_executable(Path.join(sandbox.bin, "systemd-run"), """
    #!/bin/sh
    #{stub_preamble()}
    printf 'systemd-run %s\\n' "$*" >> "$DEPLOY_SANDBOX_LOG"
    while [ $# -gt 0 ]; do
      if [ "$1" = "--" ]; then shift; break; fi
      shift
    done
    exec "$@"
    """)

    write_executable(Path.join(sandbox.bin, "chown"), """
    #!/bin/sh
    printf 'chown %s\\n' "$*" >> "$DEPLOY_SANDBOX_LOG"
    exit 0
    """)

    Enum.each(["ssh", "scp"], fn name ->
      write_executable(Path.join(sandbox.bin, name), """
      #!/bin/sh
      printf '#{name} %s\\n' "$*" >> "$DEPLOY_SANDBOX_LOG"
      exit 0
      """)
    end)
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp make_tmp_dir do
    path =
      Path.join([
        System.tmp_dir!(),
        "notable-deploy-sandbox-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(path)

    # The script resolves paths physically (`pwd -P`), and on macOS the system
    # temp dir is reached through a symlink. Resolving here keeps both sides of
    # every path comparison in the same namespace.
    {resolved, 0} = System.cmd("/bin/sh", ["-c", "cd \"$1\" && pwd -P", "sh", path])
    String.trim(resolved)
  end
end
