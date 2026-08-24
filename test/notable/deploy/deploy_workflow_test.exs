defmodule Notable.Deploy.DeployWorkflowTest do
  @moduledoc """
  Guards on the GitHub Actions workflows that can reach the live VM.

  A workflow file cannot be unit tested the way a script can, which is exactly
  why the properties that matter are asserted here: that deploying stays
  deliberate, that the runner builds something the target machine can actually
  execute, that nothing else about the target machine is baked into the repo,
  that CI's quality gate is untouched, and that the documentation still lists
  every secret an operator has to create.

  Assert properties here, not values. An earlier version of this file asserted
  `runs-on: ubuntu-latest`, which made the suite require the configuration that
  later broke production - see the runner tests below and ADR-026.
  """

  use ExUnit.Case, async: true

  @deploy_workflow ".github/workflows/deploy.yml"
  @rollback_workflow ".github/workflows/rollback.yml"
  @ci_workflow ".github/workflows/ci.yml"
  @operations_doc "docs/OPERATIONS.md"

  # Written as runner-local file paths, not read from configuration. The
  # material they hold comes from secrets, which is asserted separately.
  @runner_local_settings ~w(DEPLOY_SSH_KEY_FILE DEPLOY_SSH_KNOWN_HOSTS_FILE)

  # The deployment target, read off the live VM:
  #   Debian GNU/Linux 12 (bookworm)
  #   ldd (Debian GLIBC 2.36-9+deb12u14) 2.36
  #   x86_64
  #   libssl3 3.0.20-1~deb12u2, and no libssl1.1 package - so libcrypto.so.3
  # Update these together if the VM is ever rebuilt on another release.
  @target_os "Debian 12"
  @target_glibc "2.36"
  @target_libcrypto "libcrypto.so.3"

  # Runner image -> the ABI values verified for that image.
  #
  #   :glibc     - the image's Ubuntu release's libc6 version (22.04 = 2.35,
  #                24.04 = 2.39; see packages.ubuntu.com libc6 for the release).
  #   :libcrypto - the OpenSSL soname the release's bundled crypto NIF links
  #                against (22.04 ships libssl3 3.0.2 and 24.04 ships libssl3,
  #                so libcrypto.so.3; 20.04 shipped libssl1.1 1.1.1f, so
  #                libcrypto.so.1.1).
  #
  # These are the ABI axes that have been *checked*, not a complete list of the
  # ones that exist. The general rule is that no ABI the runner builds against
  # may exceed what the target provides; glibc and the OpenSSL soname are the
  # instances verified so far, and anyone re-pinning should look for others
  # rather than treat this list as closed.
  #
  # The image list is deliberately not exhaustive either: an image that is not
  # listed fails the tests below rather than passing unchecked, so pinning a new
  # one forces someone to look its values up first.
  @runner_abi %{
    "ubuntu-22.04" => %{glibc: "2.35", libcrypto: "libcrypto.so.3"},
    "ubuntu-24.04" => %{glibc: "2.39", libcrypto: "libcrypto.so.3"}
  }

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
    end

    # The runner image is not a style choice. `mix release` bundles ERTS built
    # against the runner's glibc, and glibc is forward-compatible only, so a
    # release built on a newer glibc than the VM's cannot start there. That is
    # not hypothetical: run 32682797726 died on
    #   beam.smp: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
    # because `ubuntu-latest` had rolled to Ubuntu 24.04 (glibc 2.39) while the
    # VM stayed on Debian 12 (glibc 2.36).
    #
    # These assert the invariant - pinned, and no newer than the target - rather
    # than a specific image. Asserting a specific image is what let the previous
    # version of this test require the broken configuration.
    test "pins the deploy runner instead of tracking a floating -latest label" do
      image = runs_on(read(@deploy_workflow))

      refute image =~ ~r/-latest$/,
             "#{@deploy_workflow}: runs-on is #{image}. A floating label silently " <>
               "re-targets the build when GitHub moves it; pin an explicit image."

      assert image =~ ~r/^ubuntu-\d+\.\d+$/,
             "#{@deploy_workflow}: runs-on is #{image}, which is not an explicitly " <>
               "versioned runner image."
    end

    test "builds on a runner whose glibc the deployment target can execute" do
      image = runs_on(read(@deploy_workflow))
      glibc = verified_abi(@deploy_workflow, image).glibc

      assert compare_versions(glibc, @target_glibc) in [:lt, :eq],
             "#{@deploy_workflow}: #{image} has glibc #{glibc}, newer than the " <>
               "deployment target's #{@target_glibc} (#{@target_os}). The release " <>
               "would build and upload, then fail to start on the VM."
    end

    # glibc is not the only ABI the release inherits from the build machine. The
    # bundled ERTS carries the crypto NIF, which links the runner's OpenSSL
    # soname, so an image with an older glibc but `libcrypto.so.1.1` would pass
    # the ordering above and still fail on a target that ships only
    # `libcrypto.so.3` - same symptom class, different axis. Sonames do not
    # order, so the runner's must be one the target actually provides.
    test "builds on a runner whose OpenSSL soname the deployment target provides" do
      image = runs_on(read(@deploy_workflow))
      libcrypto = verified_abi(@deploy_workflow, image).libcrypto

      assert libcrypto == @target_libcrypto,
             "#{@deploy_workflow}: #{image} links its crypto NIF against " <>
               "#{libcrypto}, which the deployment target does not provide - " <>
               "#{@target_os} ships #{@target_libcrypto}. The release would build " <>
               "and upload, then fail to start on the VM."
    end

    test "records in-file why the runner is pinned and that the pin will expire" do
      workflow = read(@deploy_workflow)

      assert [_, comment] = Regex.run(~r/((?:^[ \t]*#.*\n)+)[ \t]*runs-on:/m, workflow)

      for term <- ["glibc", @target_glibc, "retire"] do
        assert comment =~ term,
               "the comment above runs-on in #{@deploy_workflow} must say why the pin " <>
                 "exists and what it tracks; it never mentions #{inspect(term)}"
      end
    end

    # Only a workflow that builds a release can produce a binary the VM has to
    # execute, so only its runner image is load-bearing. Rollback reuses what is
    # already unpacked on the box and CI ships nothing, which is why neither is
    # held to the glibc rule - and why this asserts that the set of building
    # workflows has not grown.
    test "exactly one workflow builds a release, so one runner image is load-bearing" do
      builders =
        @deploy_workflow
        |> Path.dirname()
        |> Path.join("*.{yml,yaml}")
        |> Path.wildcard()
        |> Enum.filter(&(workflow_steps(File.read!(&1)) =~ "mix release"))

      assert builders == [@deploy_workflow],
             "the glibc constraint applies to every workflow that builds a release. " <>
               "Building workflows are now #{inspect(builders)}; pin each one to an " <>
               "image the deployment target can execute, and cover it here."
    end

    test "digests assets before building the release" do
      # Comments stripped: this asserts the order of the steps that run, and the
      # file's prose mentions both commands while explaining the runner pin.
      workflow = workflow_steps(read(@deploy_workflow))

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
      # Comments stripped, as in the builders test: this asserts what the
      # workflow runs, and its prose explains why its runner pin is not
      # load-bearing.
      workflow = workflow_steps(read(@rollback_workflow))

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

  # A workflow with its comment lines removed, for assertions about what the
  # workflow *does* rather than about what it says.
  defp workflow_steps(workflow) do
    workflow
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
    |> Enum.join("\n")
  end

  defp runs_on(workflow) do
    assert [_, image] = Regex.run(~r/^\s*runs-on:\s*(\S+)\s*$/m, workflow),
           "workflow declares no runs-on"

    image
  end

  # An image this test has no verified values for fails here rather than
  # skipping the checks that depend on them.
  defp verified_abi(path, image) do
    assert Map.has_key?(@runner_abi, image),
           "#{path}: runs-on is #{image}, whose ABI values this test does not know. " <>
             "Look up that image's glibc (its Ubuntu release's libc6 version) and the " <>
             "OpenSSL soname it ships, add both to @runner_abi with their source, and " <>
             "check whether any other ABI the build inherits also has to be recorded " <>
             "before pinning it."

    @runner_abi[image]
  end

  # glibc versions are `major.minor`, not semver, so compare them numerically
  # rather than lexically - "2.9" must not sort above "2.36".
  defp compare_versions(left, right) do
    left = parse_version(left)
    right = parse_version(right)

    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp parse_version(version) do
    version |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

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
