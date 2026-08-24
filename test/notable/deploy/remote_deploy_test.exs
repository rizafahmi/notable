defmodule Notable.Deploy.RemoteDeployTest do
  @moduledoc """
  Behavioural tests for `scripts/deploy/remote_deploy.sh`.

  The target VM takes live payments and can never be used as a test fixture, so
  every ordering and safety property the deploy depends on is pinned here
  against a sandboxed filesystem instead. `Notable.DeploySandbox` explains how
  the stubs make ordering observable.
  """

  use ExUnit.Case, async: true

  alias Notable.DeploySandbox

  @r1 "20260101T000000Z-aaaaaaa"
  @r2 "20260202T000000Z-bbbbbbb"
  @r3 "20260303T000000Z-ccccccc"
  @r4 "20260404T000000Z-ddddddd"
  @r5 "20260505T000000Z-eeeeeee"

  describe "activate" do
    test "unpacks into a release directory named after the release id" do
      sandbox = DeploySandbox.new()

      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      assert DeploySandbox.releases(sandbox) == [@r2]
      assert DeploySandbox.current_release(sandbox) == @r2
      assert File.read!(Path.join([sandbox.releases_dir, @r2, "RELEASE_MARKER"])) == @r2
    end

    test "points current at an absolute path so systemd resolves it from anywhere" do
      sandbox = DeploySandbox.new()

      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      assert File.read_link(sandbox.current) ==
               {:ok, Path.join([sandbox.deploy_root, "releases", @r2])}
    end

    test "migrates with the new release's own bin/migrate before swapping current" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r1)
      File.write!(sandbox.log, "")
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      log = DeploySandbox.log(sandbox)

      # The second deploy's migrate ran out of the new release directory while
      # `current` still pointed at the old one: migrate strictly precedes swap.
      assert "migrate id=#{@r2} current=#{@r1}" in log

      systemd_run = Enum.find(log, &String.starts_with?(&1, "systemd-run"))
      assert systemd_run =~ Path.join([sandbox.releases_dir, @r2, "bin/migrate"])
    end

    test "hands the env file to systemd rather than reading the secrets itself" do
      sandbox = DeploySandbox.new()
      fingerprint = DeploySandbox.env_file_fingerprint(sandbox)

      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      systemd_run =
        sandbox |> DeploySandbox.log() |> Enum.find(&String.starts_with?(&1, "systemd-run"))

      assert systemd_run =~ "EnvironmentFile=#{sandbox.env_file}"
      assert DeploySandbox.env_file_fingerprint(sandbox) == fingerprint
    end

    test "restarts the unit only after the symlink already points at the new release" do
      sandbox = DeploySandbox.new()

      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      log = DeploySandbox.log(sandbox)
      restart = Enum.find(log, &String.starts_with?(&1, "systemctl restart"))

      assert restart == "systemctl restart #{sandbox.unit} current=#{@r2}"
      assert Enum.find_index(log, &(&1 == restart)) > Enum.find_index(log, &(&1 =~ "migrate id="))
    end

    test "chowns the release to the configured user when one is set" do
      sandbox = DeploySandbox.new()

      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2, DEPLOY_RELEASE_USER: "notable")

      chown = sandbox |> DeploySandbox.log() |> Enum.find(&String.starts_with?(&1, "chown"))
      assert chown =~ "notable"
      assert chown =~ Path.join(sandbox.releases_dir, @r2)
    end

    test "leaves the running release alone when migrations fail" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r1)
      fingerprint = DeploySandbox.database_fingerprint(sandbox)
      File.write!(sandbox.log, "")
      DeploySandbox.break_migrations(sandbox)

      assert {output, status} = DeploySandbox.activate(sandbox, @r2)
      assert status != 0
      assert output =~ "migration"

      assert DeploySandbox.current_release(sandbox) == @r1
      assert DeploySandbox.releases(sandbox) == [@r1]
      refute File.exists?(Path.join(sandbox.incoming_dir, "#{@r2}.tar.gz"))
      assert staging_dirs(sandbox) == []
      assert DeploySandbox.database_fingerprint(sandbox) == fingerprint
      refute Enum.any?(DeploySandbox.log(sandbox), &(&1 =~ "systemctl restart"))
    end

    test "clears a leftover staging directory when the archive is not a release" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r1)
      fingerprint = DeploySandbox.database_fingerprint(sandbox)

      junk_dir = Path.join(sandbox.root, "junk-release")
      File.mkdir_p!(junk_dir)
      File.write!(Path.join(junk_dir, "NOT_A_RELEASE"), "nope")
      archive = Path.join(sandbox.incoming_dir, "#{@r2}.tar.gz")

      {_out, 0} =
        System.cmd("tar", ["-czf", archive, "-C", junk_dir, "."], stderr_to_stdout: true)

      assert {output, status} =
               DeploySandbox.run(sandbox, ["activate"],
                 DEPLOY_RELEASE_ID: @r2,
                 DEPLOY_RELEASE_ARCHIVE: archive
               )

      assert status != 0
      assert output =~ "does not look like a Notable release"
      assert DeploySandbox.current_release(sandbox) == @r1
      assert DeploySandbox.releases(sandbox) == [@r1]
      refute File.exists?(archive)
      assert staging_dirs(sandbox) == []
      assert DeploySandbox.database_fingerprint(sandbox) == fingerprint
    end

    test "rolls back automatically when the unit does not come up" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r1)
      DeploySandbox.break_unit_for(sandbox, @r2)

      assert {output, status} = DeploySandbox.activate(sandbox, @r2)
      assert status != 0
      assert output =~ "rolled back"
      assert DeploySandbox.current_release(sandbox) == @r1
    end

    test "refuses a release id that could escape the releases directory" do
      sandbox = DeploySandbox.new()
      archive = DeploySandbox.stage_release(sandbox, @r2)

      assert {output, status} =
               DeploySandbox.run(sandbox, ["activate"],
                 DEPLOY_RELEASE_ID: "../../etc",
                 DEPLOY_RELEASE_ARCHIVE: archive
               )

      assert status != 0
      assert output =~ "release id"
    end

    test "refuses to overwrite an existing release directory" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      assert {output, status} = DeploySandbox.activate(sandbox, @r2)
      assert status != 0
      assert output =~ "already exists"
    end

    test "fails loudly when a required setting is missing instead of guessing" do
      sandbox = DeploySandbox.new()

      assert {output, status} = DeploySandbox.activate(sandbox, @r2, DEPLOY_SYSTEMD_UNIT: "")
      assert status != 0
      assert output =~ "DEPLOY_SYSTEMD_UNIT"
    end

    test "clears the uploaded tarball but leaves an archive it did not stage" do
      sandbox = DeploySandbox.new()
      staged = DeploySandbox.stage_release(sandbox, @r2)
      elsewhere = Path.join(sandbox.root, "hand-built.tar.gz")
      File.cp!(staged, elsewhere)

      assert {_output, 0} =
               DeploySandbox.run(sandbox, ["activate"],
                 DEPLOY_RELEASE_ID: @r2,
                 DEPLOY_RELEASE_ARCHIVE: elsewhere
               )

      assert File.exists?(elsewhere)
      assert DeploySandbox.current_release(sandbox) == @r2

      assert {_output, 0} = DeploySandbox.activate(sandbox, @r3)
      refute File.exists?(Path.join(sandbox.incoming_dir, "#{@r3}.tar.gz"))
    end

    test "prunes down to the retention bound after a successful activation" do
      sandbox = DeploySandbox.new()

      Enum.each([@r1, @r2, @r3, @r4], fn id ->
        assert {_output, 0} = DeploySandbox.activate(sandbox, id, DEPLOY_KEEP_RELEASES: "3")
      end)

      assert DeploySandbox.releases(sandbox) == [@r2, @r3, @r4]
    end

    test "prunes old releases through the privileged prefix when a release user is set" do
      sandbox = DeploySandbox.new()

      Enum.each([@r1, @r2, @r3, @r4], fn id ->
        assert {_output, 0} =
                 DeploySandbox.activate(sandbox, id,
                   DEPLOY_KEEP_RELEASES: "3",
                   DEPLOY_RELEASE_USER: "notable"
                 )
      end)

      assert DeploySandbox.releases(sandbox) == [@r2, @r3, @r4]

      privileged_rms =
        sandbox
        |> DeploySandbox.log()
        |> Enum.filter(&(&1 =~ ~r/^sudo / and &1 =~ ~r/\brm\b/))

      assert Enum.any?(privileged_rms, &(&1 =~ @r1))
    end
  end

  describe "database safety" do
    test "leaves the database and its WAL companions byte-identical across deploys" do
      sandbox = DeploySandbox.new()
      fingerprint = DeploySandbox.database_fingerprint(sandbox)

      Enum.each([@r1, @r2, @r3, @r4], fn id ->
        assert {_output, 0} = DeploySandbox.activate(sandbox, id, DEPLOY_KEEP_RELEASES: "2")
      end)

      assert DeploySandbox.database_fingerprint(sandbox) == fingerprint
      refute Enum.any?(fingerprint, &match?({_name, :missing}, &1))
    end

    test "refuses to deploy at all when the database lives inside the deploy root" do
      sandbox = DeploySandbox.new()
      inside = Path.join(sandbox.deploy_root, "notable.db")
      File.write!(inside, "precious")
      DeploySandbox.put_env_database_path(sandbox, inside)

      assert {output, status} =
               DeploySandbox.activate(sandbox, @r2, DEPLOY_DATABASE_PATH: inside)

      assert status != 0
      assert output =~ "inside DEPLOY_ROOT"
      assert File.read!(inside) == "precious"
      assert DeploySandbox.releases(sandbox) == []
    end

    test "refuses to deploy when DATABASE_PATH is a symlink into a release directory" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1], @r1)

      target = Path.join([sandbox.releases_dir, @r1, "notable.db"])
      File.write!(target, "precious")

      link = Path.join(sandbox.root, "var/lib/notable/via-symlink.db")
      File.rm_rf!(link)
      File.ln_s!(target, link)
      DeploySandbox.put_env_database_path(sandbox, link)

      assert {output, status} =
               DeploySandbox.activate(sandbox, @r2, DEPLOY_DATABASE_PATH: link)

      assert status != 0
      assert output =~ "inside DEPLOY_ROOT"
      assert File.read!(target) == "precious"
      assert DeploySandbox.releases(sandbox) == [@r1]
    end

    test "refuses to deploy when the env file disagrees about where the database is" do
      sandbox = DeploySandbox.new()
      elsewhere = Path.join(sandbox.root, "var/lib/notable/other.db")

      assert {output, status} =
               DeploySandbox.activate(sandbox, @r2, DEPLOY_DATABASE_PATH: elsewhere)

      assert status != 0
      assert output =~ "DATABASE_PATH"
      assert DeploySandbox.releases(sandbox) == []
    end

    test "pruning never selects a directory holding the database file" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4], @r4)

      trapped = Path.join([sandbox.releases_dir, @r1, "notable.db"])
      File.write!(trapped, "precious")
      DeploySandbox.put_env_database_path(sandbox, trapped)

      plan =
        DeploySandbox.prune_plan(sandbox,
          DEPLOY_DATABASE_PATH: trapped,
          DEPLOY_KEEP_RELEASES: "2"
        )

      assert "protect #{Path.join(sandbox.releases_dir, @r1)} contains-database" in plan
      refute Enum.any?(plan, &(&1 == "remove #{Path.join(sandbox.releases_dir, @r1)}"))
    end

    test "pruning protects a release reached only through a DATABASE_PATH symlink" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4], @r4)

      target = Path.join([sandbox.releases_dir, @r1, "notable.db"])
      File.write!(target, "precious")

      link = Path.join(sandbox.root, "var/lib/notable/via-symlink.db")
      File.rm_rf!(link)
      File.ln_s!(target, link)
      DeploySandbox.put_env_database_path(sandbox, link)

      plan =
        DeploySandbox.prune_plan(sandbox,
          DEPLOY_DATABASE_PATH: link,
          DEPLOY_KEEP_RELEASES: "2"
        )

      assert "protect #{Path.join(sandbox.releases_dir, @r1)} contains-database" in plan
      refute Enum.any?(plan, &(&1 == "remove #{Path.join(sandbox.releases_dir, @r1)}"))
      assert File.read!(target) == "precious"
    end

    test "pruning never selects a directory holding only the WAL companions" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4], @r4)

      # The main file is elsewhere; only `-wal` strayed into a release. The
      # guard has to cover the companions too, or a prune eats the WAL and the
      # database loses its most recent committed transactions.
      trapped = Path.join([sandbox.releases_dir, @r1, "notable.db"])
      File.write!(trapped <> "-wal", "precious wal")
      DeploySandbox.put_env_database_path(sandbox, trapped)

      plan =
        DeploySandbox.prune_plan(sandbox,
          DEPLOY_DATABASE_PATH: trapped,
          DEPLOY_KEEP_RELEASES: "2"
        )

      assert "protect #{Path.join(sandbox.releases_dir, @r1)} contains-database" in plan
      assert File.exists?(trapped <> "-wal")
    end

    test "pruning skips symlinked entries rather than following them" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4], @r4)

      decoy = Path.join(sandbox.releases_dir, "00000000T000000Z-decoy")
      File.ln_s!(Path.dirname(sandbox.database_path), decoy)

      plan = DeploySandbox.prune_plan(sandbox, DEPLOY_KEEP_RELEASES: "2")

      assert "skip #{decoy} symlink" in plan
      assert File.read_link(decoy) == {:ok, Path.dirname(sandbox.database_path)}
      assert Enum.all?(DeploySandbox.database_files(sandbox), &File.exists?/1)
    end

    test "pruning ignores entries that do not look like release directories" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4], @r4)

      stray = Path.join(sandbox.releases_dir, "notes.txt")
      File.write!(stray, "operator scratch")

      plan = DeploySandbox.prune_plan(sandbox, DEPLOY_KEEP_RELEASES: "2")

      assert "skip #{stray} not-a-release-directory" in plan
      assert File.exists?(stray)
    end

    test "pruning reclaims a planted staging orphan from a crashed unpack" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2], @r2)

      staging = Path.join(sandbox.releases_dir, ".staging-#{@r3}.99999")
      File.mkdir_p!(staging)
      File.write!(Path.join(staging, "partial"), "crash leftover")

      plan = DeploySandbox.prune_plan(sandbox, DEPLOY_KEEP_RELEASES: "2")

      assert "reclaim #{staging} staging-orphan" in plan
      refute Enum.any?(plan, &(&1 == "remove #{staging}"))
      refute Enum.any?(plan, &(&1 =~ "skip #{staging}"))
    end

    test "pruning protects a staging orphan that contains the database" do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2], @r2)

      staging = Path.join(sandbox.releases_dir, ".staging-#{@r3}.99999")
      File.mkdir_p!(staging)
      trapped = Path.join(staging, "notable.db")
      File.write!(trapped, "precious")
      DeploySandbox.put_env_database_path(sandbox, trapped)

      plan =
        DeploySandbox.prune_plan(sandbox,
          DEPLOY_DATABASE_PATH: trapped,
          DEPLOY_KEEP_RELEASES: "2"
        )

      assert "protect #{staging} contains-database" in plan
      refute Enum.any?(plan, &(&1 =~ "reclaim #{staging}"))
      assert File.read!(trapped) == "precious"
    end
  end

  describe "prune retention boundary" do
    setup do
      sandbox = DeploySandbox.new()
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4, @r5], @r5)
      %{sandbox: sandbox}
    end

    test "removes exactly the releases outside the newest N", %{sandbox: sandbox} do
      plan = DeploySandbox.prune_plan(sandbox, DEPLOY_KEEP_RELEASES: "3")

      assert removals(plan, sandbox) == [@r1, @r2]
    end

    test "keeps everything when the retention bound exceeds the release count",
         %{sandbox: sandbox} do
      plan = DeploySandbox.prune_plan(sandbox, DEPLOY_KEEP_RELEASES: "9")

      assert removals(plan, sandbox) == []
    end

    test "retains the current release and its rollback target even when both are old",
         %{sandbox: sandbox} do
      DeploySandbox.seed_releases(sandbox, [@r1, @r2, @r3, @r4, @r5], @r2)

      plan = DeploySandbox.prune_plan(sandbox, DEPLOY_KEEP_RELEASES: "2")

      # Newest two (@r5, @r4) by policy, plus current (@r2) and the release it
      # would roll back to (@r1). Only @r3 is expendable.
      assert removals(plan, sandbox) == [@r3]
    end

    test "refuses a retention bound that would leave nothing to roll back to",
         %{sandbox: sandbox} do
      assert {output, status} =
               DeploySandbox.run(sandbox, ["prune-plan"], DEPLOY_KEEP_RELEASES: "1")

      assert status != 0
      assert output =~ "DEPLOY_KEEP_RELEASES"
    end
  end

  describe "rollback" do
    setup do
      sandbox = DeploySandbox.new()

      Enum.each([@r1, @r2, @r3], fn id ->
        assert {_output, 0} = DeploySandbox.activate(sandbox, id)
      end)

      File.write!(sandbox.log, "")
      %{sandbox: sandbox}
    end

    test "selects the newest release strictly older than current", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.rollback(sandbox)
      assert DeploySandbox.current_release(sandbox) == @r2

      # Rolling back again keeps walking backwards instead of ping-ponging
      # between the last two releases.
      assert {_output, 0} = DeploySandbox.rollback(sandbox)
      assert DeploySandbox.current_release(sandbox) == @r1
    end

    test "restarts the unit after the symlink has already moved", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.rollback(sandbox)

      restart =
        sandbox |> DeploySandbox.log() |> Enum.find(&String.starts_with?(&1, "systemctl restart"))

      assert restart == "systemctl restart #{sandbox.unit} current=#{@r2}"
    end

    test "never runs migrations", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.rollback(sandbox)

      refute Enum.any?(DeploySandbox.log(sandbox), &(&1 =~ "migrate"))
    end

    test "accepts an explicit release id", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.rollback(sandbox, [@r1])
      assert DeploySandbox.current_release(sandbox) == @r1
    end

    test "refuses an unknown release id", %{sandbox: sandbox} do
      assert {output, status} = DeploySandbox.rollback(sandbox, ["20260909T000000Z-nope"])

      assert status != 0
      assert output =~ "no such release"
      assert DeploySandbox.current_release(sandbox) == @r3
    end

    test "refuses when nothing older than current exists", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.rollback(sandbox, [@r1])

      assert {output, status} = DeploySandbox.rollback(sandbox)
      assert status != 0
      assert output =~ "no earlier release"
      assert DeploySandbox.current_release(sandbox) == @r1
    end

    test "does not prune", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.rollback(sandbox, [@r1], DEPLOY_KEEP_RELEASES: "2")
      assert DeploySandbox.releases(sandbox) == [@r1, @r2, @r3]
    end

    test "refuses when only a staging orphan exists beside current" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r1)

      staging = Path.join(sandbox.releases_dir, ".staging-#{@r2}.4242")
      File.mkdir_p!(staging)
      File.write!(Path.join(staging, "partial"), "oom leftover")

      assert {output, status} = DeploySandbox.rollback(sandbox)
      assert status != 0
      assert output =~ "no earlier release"
      assert DeploySandbox.current_release(sandbox) == @r1
      assert File.dir?(staging)
    end

    test "selects a real older release rather than a staging sibling" do
      sandbox = DeploySandbox.new()
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r1)
      assert {_output, 0} = DeploySandbox.activate(sandbox, @r2)

      staging = Path.join(sandbox.releases_dir, ".staging-#{@r3}.4242")
      File.mkdir_p!(staging)
      File.write!(Path.join(staging, "partial"), "oom leftover")

      assert {_output, 0} = DeploySandbox.rollback(sandbox)
      assert DeploySandbox.current_release(sandbox) == @r1
      assert File.dir?(staging)
    end
  end

  defp removals(plan, sandbox) do
    prefix = sandbox.releases_dir <> "/"

    plan
    |> Enum.filter(&String.starts_with?(&1, "remove " <> prefix))
    |> Enum.map(&String.replace_prefix(&1, "remove " <> prefix, ""))
    |> Enum.sort()
  end

  defp staging_dirs(sandbox) do
    sandbox.releases_dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".staging-"))
    |> Enum.sort()
  end
end
