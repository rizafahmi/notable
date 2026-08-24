defmodule Notable.Deploy.DeployWorkflowTest do
  @moduledoc """
  Guards on the GitHub Actions workflows that can reach the live VM.

  A workflow file cannot be unit tested the way a script can, which is exactly
  why the properties that matter are asserted here: that deploying stays
  deliberate, that nothing about the target machine is baked into the repo,
  that CI's quality gate is untouched, and that the documentation still lists
  every secret an operator has to create.
  """

  use ExUnit.Case, async: true

  @deploy_workflow ".github/workflows/deploy.yml"
  @rollback_workflow ".github/workflows/rollback.yml"
  @ci_workflow ".github/workflows/ci.yml"
  @operations_doc "docs/OPERATIONS.md"

  # Written as runner-local file paths, not read from configuration. The
  # material they hold comes from secrets, which is asserted separately.
  @runner_local_settings ~w(DEPLOY_SSH_KEY_FILE DEPLOY_SSH_KNOWN_HOSTS_FILE)

  describe "deploy workflow" do
    test "is dispatched deliberately and never fires on a push or a pull request" do
      workflow = read(@deploy_workflow)

      assert workflow =~ ~r/^on:$/m
      assert workflow =~ ~r/^\s{2}workflow_dispatch:$/m
      refute workflow =~ ~r/^\s{2}push:$/m
      refute workflow =~ ~r/^\s{2}pull_request:$/m
      refute workflow =~ ~r/^\s{2}schedule:$/m
    end

    test "documents in-file the exact edit that would make it deploy on merge" do
      workflow = read(@deploy_workflow)

      assert workflow =~ "deploy on merge"
      assert workflow =~ ~r/^#\s+push:$/m
      assert workflow =~ ~r/^#\s+branches: \[main\]$/m
    end

    test "serialises deploys so two runs cannot race for the current symlink" do
      assert read(@deploy_workflow) =~ ~r/^concurrency:$/m
      assert read(@deploy_workflow) =~ "cancel-in-progress: false"
    end

    test "builds the release on the runner with the versions CI already pins" do
      workflow = read(@deploy_workflow)
      ci = read(@ci_workflow)

      assert [_, elixir] = Regex.run(~r/elixir-version: "([^"]+)"/, ci)
      assert [_, otp] = Regex.run(~r/otp-version: "([^"]+)"/, ci)

      assert workflow =~ ~s(elixir-version: "#{elixir}")
      assert workflow =~ ~s(otp-version: "#{otp}")
      assert workflow =~ "runs-on: ubuntu-latest"
    end

    test "digests assets before building the release" do
      workflow = read(@deploy_workflow)

      assets = index_of(workflow, "mix assets.deploy")
      release = index_of(workflow, "mix release")

      assert assets < release
      assert workflow =~ ~r/MIX_ENV: prod/
    end

    test "hands the deploy itself to the tested script rather than inlining it" do
      workflow = read(@deploy_workflow)

      assert workflow =~ "scripts/deploy/ssh_deploy.sh activate"
      refute workflow =~ "remote_deploy.sh activate"
    end

    test "never names the target machine, its paths, or its service" do
      for path <- [@deploy_workflow, @rollback_workflow] do
        workflow = read(path)

        for {setting, value} <- deploy_settings(workflow) do
          assert value =~ ~r/\$\{\{\s*(secrets|vars)\./,
                 "#{path}: #{setting} must come from a secret or variable, got #{value}"
        end
      end
    end

    test "materialises the SSH credentials from secrets at run time" do
      for path <- [@deploy_workflow, @rollback_workflow] do
        workflow = read(path)

        assert workflow =~ "secrets.DEPLOY_SSH_KEY"
        assert workflow =~ "secrets.DEPLOY_SSH_KNOWN_HOSTS"
        assert workflow =~ ~r/chmod 600/, "#{path} must not leave the key world readable"
      end
    end

    test "removes the private key from the runner even when the deploy fails" do
      for path <- [@deploy_workflow, @rollback_workflow] do
        workflow = read(path)

        assert workflow =~ "if: always()"
        assert workflow =~ ~r/rm -f .*deploy_key/
      end
    end

    test "asks for no more permission than reading the repository" do
      for path <- [@deploy_workflow, @rollback_workflow] do
        assert read(path) =~ "permissions:\n  contents: read"
      end
    end
  end

  describe "rollback workflow" do
    test "is dispatchable on its own and calls the tested script" do
      workflow = read(@rollback_workflow)

      assert workflow =~ ~r/^\s{2}workflow_dispatch:$/m
      refute workflow =~ ~r/^\s{2}push:$/m
      assert workflow =~ "scripts/deploy/ssh_deploy.sh rollback"
    end

    test "accepts an optional explicit release id" do
      workflow = read(@rollback_workflow)

      assert workflow =~ "release_id:"
      assert workflow =~ "inputs.release_id"
    end

    test "does not build anything, because rollback reuses what is on the box" do
      workflow = read(@rollback_workflow)

      refute workflow =~ "mix release"
      refute workflow =~ "mix assets.deploy"
    end
  end

  describe "existing CI" do
    test "still runs the quality gate on pushes to main and on pull requests" do
      ci = read(@ci_workflow)

      assert ci =~ ~r/^\s{2}push:$/m
      assert ci =~ ~r/^\s{4}branches: \[main\]$/m
      assert ci =~ ~r/^\s{2}pull_request:$/m
      assert ci =~ "run: mix ci"
    end

    test "still installs OpenCV so the QR decode tests actually run" do
      ci = read(@ci_workflow)

      assert ci =~ "opencv-python-headless"
      assert ci =~ "actions/setup-python"
    end

    test "never deploys" do
      ci = read(@ci_workflow)

      refute ci =~ "ssh_deploy.sh"
      refute ci =~ "remote_deploy.sh"
    end
  end

  describe "documentation" do
    test "operations doc lists every secret and variable the workflows reference" do
      documented = read(@operations_doc)

      for path <- [@deploy_workflow, @rollback_workflow],
          {kind, name} <- referenced_settings(read(path)) do
        assert documented =~ name,
               "#{path} reads #{kind}.#{name} but #{@operations_doc} never mentions it"
      end
    end

    test "operations doc explains triggering, rollback, and deploy-on-merge" do
      documented = read(@operations_doc)

      assert documented =~ "workflow_dispatch"
      assert documented =~ @deploy_workflow
      assert documented =~ @rollback_workflow
      assert documented =~ "deploy on merge"
    end
  end

  defp read(path), do: File.read!(Path.join(File.cwd!(), path))

  defp index_of(text, needle) do
    assert [{index, _length}] = Regex.run(~r/#{Regex.escape(needle)}/, text, return: :index)
    index
  end

  # Every `DEPLOY_*: <value>` mapping in a workflow, minus the two settings that
  # are deliberately runner-local paths.
  defp deploy_settings(workflow) do
    ~r/^\s*(DEPLOY_[A-Z0-9_]+):\s*(\S.*)$/m
    |> Regex.scan(workflow)
    |> Enum.map(fn [_line, setting, value] -> {setting, String.trim(value)} end)
    |> Enum.reject(fn {setting, _value} -> setting in @runner_local_settings end)
  end

  defp referenced_settings(workflow) do
    ~r/\$\{\{\s*(secrets|vars)\.([A-Z0-9_]+)/
    |> Regex.scan(workflow)
    |> Enum.map(fn [_match, kind, name] -> {kind, name} end)
    |> Enum.reject(fn {_kind, name} -> name == "GITHUB_TOKEN" end)
    |> Enum.uniq()
  end
end
