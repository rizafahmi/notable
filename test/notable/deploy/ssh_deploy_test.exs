defmodule Notable.Deploy.SshDeployTest do
  @moduledoc """
  Tests for `scripts/deploy/ssh_deploy.sh`, the CI half of the deploy.

  This script decides which machine is contacted, what is uploaded, and which
  settings the remote script runs with. Getting any of that wrong is how a
  deploy reaches a box nobody intended, so `ssh` and `scp` are stubbed and the
  composed invocations are asserted directly.
  """

  use ExUnit.Case, async: true

  alias Notable.DeploySandbox

  @release_id "20260730T101500Z-a1b2c3d"

  setup do
    sandbox = DeploySandbox.new()
    %{sandbox: sandbox, artifact: DeploySandbox.build_artifact(sandbox, @release_id)}
  end

  describe "activate" do
    test "uploads the release archive and the remote script before invoking it",
         %{sandbox: sandbox, artifact: artifact} do
      assert {_output, 0} = activate(sandbox, artifact)

      log = DeploySandbox.log(sandbox)
      upload = Enum.find(log, &(String.starts_with?(&1, "scp ") and &1 =~ artifact))

      remote_script =
        Enum.find(log, &(String.starts_with?(&1, "scp ") and &1 =~ "remote_deploy.sh"))

      invoke = Enum.find(log, &(String.starts_with?(&1, "ssh ") and &1 =~ "remote_deploy.sh"))

      assert upload =~ "#{sandbox.deploy_root}/incoming/#{@release_id}.tar.gz"
      assert remote_script =~ "#{sandbox.deploy_root}/bin/remote_deploy.sh"

      assert Enum.find_index(log, &(&1 == invoke)) > Enum.find_index(log, &(&1 == upload))

      assert Enum.find_index(log, &(&1 == invoke)) >
               Enum.find_index(log, &(&1 == remote_script))
    end

    test "passes every host-specific setting through to the remote script",
         %{sandbox: sandbox, artifact: artifact} do
      assert {_output, 0} =
               activate(sandbox, artifact,
                 DEPLOY_RELEASE_USER: "notable",
                 DEPLOY_KEEP_RELEASES: "7"
               )

      invoke = remote_invocation(sandbox)

      assert invoke =~ "DEPLOY_ROOT='#{sandbox.deploy_root}'"
      assert invoke =~ "DEPLOY_SYSTEMD_UNIT='#{sandbox.unit}'"
      assert invoke =~ "DEPLOY_DATABASE_PATH='#{sandbox.database_path}'"
      assert invoke =~ "DEPLOY_ENV_FILE='#{sandbox.env_file}'"
      assert invoke =~ "DEPLOY_RELEASE_USER='notable'"
      assert invoke =~ "DEPLOY_KEEP_RELEASES='7'"
      assert invoke =~ "DEPLOY_RELEASE_ID='#{@release_id}'"

      assert invoke =~
               "DEPLOY_RELEASE_ARCHIVE='#{sandbox.deploy_root}/incoming/#{@release_id}.tar.gz'"

      assert invoke =~ "activate"
      refute invoke =~ "DEPLOY_PRIVILEGED_CMD="
    end

    test "forwards an explicitly empty DEPLOY_PRIVILEGED_CMD as a manual knob",
         %{sandbox: sandbox, artifact: artifact} do
      assert {_output, 0} = activate(sandbox, artifact, DEPLOY_PRIVILEGED_CMD: "")

      assert remote_invocation(sandbox) =~ "DEPLOY_PRIVILEGED_CMD=''"
    end

    test "verifies the host key instead of trusting whatever answers",
         %{sandbox: sandbox, artifact: artifact} do
      {key_file, _material} = DeploySandbox.ssh_key(sandbox)

      assert {_output, 0} = activate(sandbox, artifact)

      invoke = remote_invocation(sandbox)

      assert invoke =~ "StrictHostKeyChecking=yes"
      assert invoke =~ "UserKnownHostsFile=#{Path.join(sandbox.root, "known_hosts")}"
      assert invoke =~ "BatchMode=yes"
      assert invoke =~ "IdentitiesOnly=yes"
      assert invoke =~ "-i #{key_file}"
      assert invoke =~ "-p 2222"
      assert invoke =~ "deployer@deploy.example.test"
      refute invoke =~ "StrictHostKeyChecking=no"
    end

    test "never echoes the private key material", %{sandbox: sandbox, artifact: artifact} do
      {_key_file, material} = DeploySandbox.ssh_key(sandbox)

      assert {output, 0} = activate(sandbox, artifact)

      refute output =~ "supersecret"
      refute Enum.any?(DeploySandbox.log(sandbox), &(&1 =~ "supersecret"))
      refute output =~ String.trim(material)
    end

    test "refuses to run when the host is not configured",
         %{sandbox: sandbox, artifact: artifact} do
      assert {output, status} = activate(sandbox, artifact, DEPLOY_SSH_HOST: "")

      assert status != 0
      assert output =~ "DEPLOY_SSH_HOST"
      assert DeploySandbox.log(sandbox) == []
    end

    test "refuses to run when the built artifact is missing", %{sandbox: sandbox} do
      assert {output, status} =
               DeploySandbox.ssh_deploy(sandbox, ["activate"],
                 RELEASE_ID: @release_id,
                 RELEASE_ARCHIVE: Path.join(sandbox.root, "nope.tar.gz")
               )

      assert status != 0
      assert output =~ "nope.tar.gz"
    end
  end

  describe "rollback" do
    test "invokes the remote rollback without uploading an archive", %{sandbox: sandbox} do
      assert {_output, 0} = DeploySandbox.ssh_deploy(sandbox, ["rollback"])

      log = DeploySandbox.log(sandbox)
      refute Enum.any?(log, &(String.starts_with?(&1, "scp ") and &1 =~ ".tar.gz"))

      invoke = remote_invocation(sandbox)
      assert invoke =~ "remote_deploy.sh' 'rollback'"
    end

    test "forwards an explicit release id", %{sandbox: sandbox} do
      assert {_output, 0} =
               DeploySandbox.ssh_deploy(sandbox, ["rollback", "20260101T000000Z-old"])

      assert remote_invocation(sandbox) =~ "'rollback' '20260101T000000Z-old'"
    end

    test "refuses a release id that is not a valid release name", %{sandbox: sandbox} do
      assert {output, status} = DeploySandbox.ssh_deploy(sandbox, ["rollback", "../../etc"])

      assert status != 0
      assert output =~ "release id"
    end
  end

  defp activate(sandbox, artifact, extra_env \\ []) do
    defaults = [RELEASE_ID: @release_id, RELEASE_ARCHIVE: artifact]
    DeploySandbox.ssh_deploy(sandbox, ["activate"], Keyword.merge(defaults, extra_env))
  end

  defp remote_invocation(sandbox) do
    sandbox
    |> DeploySandbox.log()
    |> Enum.find(&(String.starts_with?(&1, "ssh ") and &1 =~ "remote_deploy.sh'"))
  end
end
