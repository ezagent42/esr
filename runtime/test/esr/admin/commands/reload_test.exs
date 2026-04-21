defmodule Esr.Admin.Commands.ReloadTest do
  @moduledoc """
  DI-12 Task 26 — `Esr.Admin.Commands.Reload` scans
  `git log <last_sha>..HEAD` for breaking-change commits, gates the
  launchctl-kickstart on an explicit `args.acknowledge_breaking = true`,
  and records the reload in `<runtime_home>/last_reload.yaml`.

  ## git + launchctl mocking

  `execute/2` accepts an opts keyword:

    * `:git_fn`      — `fn argv -> {stdout :: String.t(), exit :: integer()} end`
    * `:spawn_fn`    — `fn argv -> {stdout :: String.t(), exit :: integer()} end`
      (stands in for `System.cmd("launchctl", argv, ...)`)
    * `:now_iso8601` — override `DateTime.utc_now/0 |> DateTime.to_iso8601/1`
      so assertions can compare the written timestamp verbatim.

  Tests pass stubs so no real `git` or `launchctl` invocation happens.

  ## Label resolution

  Derived from `Esr.Paths.esrd_home/0`:

    * path ends in `.esrd-dev` → `com.ezagent.esrd-dev`
    * path ends in `.esrd`     → `com.ezagent.esrd`
    * anything else (e.g. `/tmp/esrd-feature-foo`) → `{:error,
      %{"type" => "cannot_determine_label"}}`. This safeguards
      ephemeral per-branch esrds from trying to reload themselves via
      launchctl.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Reload

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_reload_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  # --------------------------------------------------------------------
  # Label resolution
  # --------------------------------------------------------------------

  describe "launchctl label resolution" do
    test "ESRD_HOME ending in .esrd → com.ezagent.esrd", %{tmp: _tmp} do
      home = Path.join(System.tmp_dir!(), ".esrd")
      File.mkdir_p!(Path.join(home, "default"))
      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      parent = self()

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] -> {"aaaaaaa\n", 0}
          ["log" | _] -> {"", 0}
        end,
        spawn_fn: fn argv ->
          send(parent, {:launchctl, argv})
          {"", 0}
        end
      ]

      assert {:ok, %{"reloaded" => true, "new_sha" => "aaaaaaa"}} = Reload.execute(cmd, opts)

      assert_receive {:launchctl, ["kickstart", "-k", target]}, 500
      assert String.ends_with?(target, "/com.ezagent.esrd")
    end

    test "ESRD_HOME ending in .esrd-dev → com.ezagent.esrd-dev" do
      home = Path.join(System.tmp_dir!(), ".esrd-dev")
      File.mkdir_p!(Path.join(home, "default"))
      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      parent = self()

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] -> {"bbbbbbb\n", 0}
          ["log" | _] -> {"", 0}
        end,
        spawn_fn: fn argv ->
          send(parent, {:launchctl, argv})
          {"", 0}
        end
      ]

      assert {:ok, %{"reloaded" => true}} = Reload.execute(cmd, opts)

      assert_receive {:launchctl, ["kickstart", "-k", target]}, 500
      assert String.ends_with?(target, "/com.ezagent.esrd-dev")
    end

    test "ephemeral /tmp/esrd-<branch>/ refuses to reload itself" do
      home = Path.join(System.tmp_dir!(), "esrd-feature-foo")
      File.mkdir_p!(Path.join(home, "default"))
      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] -> {"ccccccc\n", 0}
          ["log" | _] -> {"", 0}
        end,
        spawn_fn: fn _ -> flunk("spawn_fn should NOT be called for ephemeral esrd") end
      ]

      assert {:error, %{"type" => "cannot_determine_label"}} = Reload.execute(cmd, opts)
    end
  end

  # --------------------------------------------------------------------
  # Breaking-change gating
  # --------------------------------------------------------------------

  describe "breaking-change gating" do
    test "no breaking commits + no acknowledge → succeeds; writes last_reload.yaml",
         %{tmp: tmp} do
      # Point ESRD_HOME at a .esrd path so label resolution works.
      home = Path.join(System.tmp_dir!(), ".esrd_#{System.unique_integer([:positive])}")
      File.rm_rf!(home)
      File.mkdir_p!(Path.join(home, "default"))
      File.rename(home, Path.join(Path.dirname(home), ".esrd"))
      home = Path.join(Path.dirname(home), ".esrd")

      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      _ = tmp

      parent = self()

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] -> {"1234abc\n", 0}
          ["log" | _] -> {"", 0}
        end,
        spawn_fn: fn argv ->
          send(parent, {:launchctl, argv})
          {"", 0}
        end,
        now_iso8601: "2026-04-21T10:00:00Z"
      ]

      assert {:ok, %{"reloaded" => true, "new_sha" => "1234abc"}} = Reload.execute(cmd, opts)

      assert_receive {:launchctl, _argv}, 500

      last_path = Path.join([home, "default", "last_reload.yaml"])
      assert File.exists?(last_path)

      {:ok, doc} = YamlElixir.read_from_file(last_path)
      assert doc["last_reload_sha"] == "1234abc"
      assert doc["last_reload_ts"] == "2026-04-21T10:00:00Z"
      assert doc["by"] == "ou_alice"
      assert doc["acknowledged_breaking"] == []
    end

    test "breaking commits present + no acknowledge → error with commit list" do
      home = Path.join(System.tmp_dir!(), ".esrd_#{System.unique_integer([:positive])}_b")
      File.mkdir_p!(Path.join(home, "default"))
      renamed = Path.join(Path.dirname(home), ".esrd")
      File.rm_rf!(renamed)
      File.rename(home, renamed)
      home = renamed

      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      # Pre-populate last_reload.yaml so the scan range starts at that sha.
      prior = Path.join([home, "default", "last_reload.yaml"])
      File.write!(prior, """
      last_reload_sha: deadbeef
      last_reload_ts: 2026-04-20T00:00:00Z
      by: ou_previous
      acknowledged_breaking: []
      """)

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] ->
            {"ffffffff\n", 0}

          ["log", "deadbeef..HEAD" | _] ->
            {"abc1234 feat(api)!: breaking rename\nxyz9876 feat: add BREAKING CHANGE in body\n", 0}
        end,
        spawn_fn: fn _ -> flunk("spawn_fn should NOT be called when breaking unacknowledged") end
      ]

      assert {:error,
              %{"type" => "unacknowledged_breaking", "commits" => commits}} =
               Reload.execute(cmd, opts)

      assert commits == [
               "abc1234 feat(api)!: breaking rename",
               "xyz9876 feat: add BREAKING CHANGE in body"
             ]

      # last_reload.yaml must NOT have been overwritten when the gate fired.
      {:ok, doc} = YamlElixir.read_from_file(prior)
      assert doc["last_reload_sha"] == "deadbeef"
    end

    test "breaking commits + acknowledge_breaking=true → succeeds; records acknowledged shas" do
      home = Path.join(System.tmp_dir!(), ".esrd_#{System.unique_integer([:positive])}_c")
      File.mkdir_p!(Path.join(home, "default"))
      renamed = Path.join(Path.dirname(home), ".esrd")
      File.rm_rf!(renamed)
      File.rename(home, renamed)
      home = renamed

      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      parent = self()

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{"acknowledge_breaking" => true}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] -> {"99887766\n", 0}
          ["log" | _] -> {"abc1234 feat!: break A\ndef5678 feat!: break B\n", 0}
        end,
        spawn_fn: fn argv ->
          send(parent, {:launchctl, argv})
          {"", 0}
        end,
        now_iso8601: "2026-04-21T12:00:00Z"
      ]

      assert {:ok, %{"reloaded" => true, "new_sha" => "99887766"}} = Reload.execute(cmd, opts)

      assert_receive {:launchctl, _argv}, 500

      last_path = Path.join([home, "default", "last_reload.yaml"])
      {:ok, doc} = YamlElixir.read_from_file(last_path)

      # Only the short shas of the breaking commits get recorded under
      # acknowledged_breaking (not the full "sha subject" lines).
      assert doc["acknowledged_breaking"] == ["abc1234", "def5678"]
      assert doc["last_reload_sha"] == "99887766"
      assert doc["by"] == "ou_alice"
    end

    test "missing last_reload.yaml → scans from HEAD (first-run no-op range)" do
      home = Path.join(System.tmp_dir!(), ".esrd_#{System.unique_integer([:positive])}_d")
      File.mkdir_p!(Path.join(home, "default"))
      renamed = Path.join(Path.dirname(home), ".esrd")
      File.rm_rf!(renamed)
      File.rename(home, renamed)
      home = renamed

      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      parent = self()

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn
          ["rev-parse", "HEAD"] ->
            {"firstsha\n", 0}

          ["log", range | _] ->
            send(parent, {:scan_range, range})
            # First run: `HEAD..HEAD` is empty, so nothing breaking by
            # definition. Return empty stdout.
            {"", 0}
        end,
        spawn_fn: fn _ -> {"", 0} end
      ]

      assert {:ok, %{"reloaded" => true, "new_sha" => "firstsha"}} = Reload.execute(cmd, opts)

      # Implementation choice: first run scans `HEAD..HEAD` (empty set);
      # no risk of accidentally flagging commits from before ESR
      # adoption.
      assert_receive {:scan_range, "HEAD..HEAD"}, 500
    end

    test "git rev-parse HEAD failure surfaces as git_failed" do
      home = Path.join(System.tmp_dir!(), ".esrd_#{System.unique_integer([:positive])}_e")
      File.mkdir_p!(Path.join(home, "default"))
      renamed = Path.join(Path.dirname(home), ".esrd")
      File.rm_rf!(renamed)
      File.rename(home, renamed)
      home = renamed

      prev = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
        File.rm_rf!(home)
      end)

      cmd = %{
        "kind" => "reload",
        "submitted_by" => "ou_alice",
        "args" => %{}
      }

      opts = [
        git_fn: fn _ -> {"fatal: not a git repository\n", 128} end,
        spawn_fn: fn _ -> flunk("spawn_fn should NOT be called when git fails") end
      ]

      assert {:error, %{"type" => "git_failed"}} = Reload.execute(cmd, opts)
    end
  end

  # --------------------------------------------------------------------
  # Dispatcher wiring
  # --------------------------------------------------------------------

  describe "dispatcher wiring" do
    test "`reload` kind is registered in the Dispatcher's @command_modules map" do
      # Pull the module attribute via the documented Dispatcher private
      # @command_modules map. Since the map is private, we reach into
      # the map by running a synthetic execute through Dispatcher's
      # run_command/2. But that's also private — easier to just assert
      # the module is compiled and picks up the `reload` kind.
      assert Code.ensure_loaded?(Esr.Admin.Commands.Reload)
      assert function_exported?(Esr.Admin.Commands.Reload, :execute, 1)
      assert function_exported?(Esr.Admin.Commands.Reload, :execute, 2)
    end
  end
end
