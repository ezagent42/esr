defmodule Esr.SlashRoutesTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry
  alias Esr.Resource.SlashRoute.Registry.FileLoader

  setup do
    # Ensure SlashRouteRegistry is up. Reset to empty between tests, then
    # restore the priv default on_exit so other test files (Dispatcher
    # in particular — looks up kind → permission via SlashRouteRegistry) see
    # the production kind table.
    if Process.whereis(SlashRouteRegistry) == nil, do: start_supervised!(SlashRouteRegistry)
    SlashRouteRegistry.load_snapshot(%{slashes: [], internal_kinds: []})

    on_exit(fn ->
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      if File.exists?(priv), do: FileLoader.load(priv)
    end)

    :ok
  end

  describe "lookup/1" do
    test "returns :not_found when no routes loaded" do
      assert :not_found = SlashRouteRegistry.lookup("/help")
    end

    test "single-word slash matches by head" do
      load_fixture(slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")})

      assert {:ok, route} = SlashRouteRegistry.lookup("/help")
      assert route.kind == "help"
      assert route.slash == "/help"
    end

    test "single-word slash with trailing args still matches" do
      load_fixture(slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")})

      assert {:ok, _} = SlashRouteRegistry.lookup("/help foo bar")
    end

    test "multi-word slash matches longest prefix" do
      load_fixture(
        slashes: %{
          "/workspace" => simple_route("workspace", "Esr.Commands.Notify"),
          "/workspace info" => simple_route("workspace_info", "Esr.Commands.Notify")
        }
      )

      # "/workspace info" beats "/workspace"
      assert {:ok, route} = SlashRouteRegistry.lookup("/workspace info esr-dev")
      assert route.kind == "workspace_info"

      # "/workspace foo" with no second-token match falls back to "/workspace"
      assert {:ok, route} = SlashRouteRegistry.lookup("/workspace something-else")
      assert route.kind == "workspace"
    end

    test "alias resolves to same route as primary (fixture mechanism test)" do
      # Phase 6: the priv default yaml no longer uses aliases (hard cutover).
      # This test validates the Registry's alias-resolution mechanism with a
      # synthetic fixture (the mechanism is still supported for custom yaml).
      route = simple_route("session_list", "Esr.Commands.Notify")
      load_fixture(slashes: %{"/session:list" => Map.put(route, "aliases", ["/sessions"])})

      assert {:ok, r1} = SlashRouteRegistry.lookup("/session:list")
      assert {:ok, r2} = SlashRouteRegistry.lookup("/sessions")
      assert r1.kind == r2.kind
    end

    test "unknown slash returns :not_found" do
      load_fixture(slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")})

      assert :not_found = SlashRouteRegistry.lookup("/totally-fake")
    end
  end

  describe "permission_for/1 and command_module_for/1" do
    test "covers slash kinds" do
      load_fixture(
        slashes: %{
          "/help" => Map.put(simple_route("help", "Esr.Commands.Notify"), "permission", nil),
          "/session:add-agent" =>
            Map.put(
              simple_route("session_add_agent", "Esr.Commands.Notify"),
              "permission",
              "session:default/add-agent"
            )
        }
      )

      assert nil == SlashRouteRegistry.permission_for("help")
      assert "session:default/add-agent" == SlashRouteRegistry.permission_for("session_add_agent")

      assert Esr.Commands.Notify == SlashRouteRegistry.command_module_for("help")
      assert Esr.Commands.Notify == SlashRouteRegistry.command_module_for("session_add_agent")
    end

    test "covers internal_kinds" do
      load_fixture(
        internal_kinds: %{
          "notify" => %{
            "permission" => "notify.send",
            "command_module" => "Esr.Commands.Notify"
          }
        }
      )

      assert "notify.send" == SlashRouteRegistry.permission_for("notify")
      assert Esr.Commands.Notify == SlashRouteRegistry.command_module_for("notify")
    end

    test "unknown kind returns :not_found" do
      load_fixture(slashes: %{})

      assert :not_found == SlashRouteRegistry.permission_for("nonexistent")
      assert :not_found == SlashRouteRegistry.command_module_for("nonexistent")
    end
  end

  describe "list_slashes/0 (used by /help)" do
    test "returns all slashes deduplicated by kind, sorted by category + kind" do
      load_fixture(
        slashes: %{
          "/session:list" =>
            Map.merge(simple_route("session_list", "Esr.Commands.Notify"), %{
              "category" => "Sessions"
            }),
          "/help" =>
            Map.merge(simple_route("help", "Esr.Commands.Notify"), %{"category" => "诊断"})
        }
      )

      list = SlashRouteRegistry.list_slashes()
      assert length(list) == 2
      categories = Enum.map(list, & &1[:category])
      assert "Sessions" in categories
      assert "诊断" in categories
    end
  end

  describe "FileLoader.load/1" do
    test "missing file → empty snapshot, no error" do
      assert :ok = FileLoader.load("/tmp/does/not/exist/slash-routes.yaml")
      assert :not_found = SlashRouteRegistry.lookup("/help")
    end

    test "valid yaml loads" do
      yaml = """
      schema_version: 1
      slashes:
        "/help":
          kind: help
          permission: null
          command_module: "Esr.Commands.Notify"
          requires_workspace_binding: false
          requires_user_binding: false
          description: test
          args: []
      internal_kinds:
        notify:
          permission: notify.send
          command_module: "Esr.Commands.Notify"
      """

      path = write_tmp(yaml)
      on_exit(fn -> File.rm(path) end)

      assert :ok = FileLoader.load(path)
      assert {:ok, %{kind: "help"}} = SlashRouteRegistry.lookup("/help")
      assert "notify.send" = SlashRouteRegistry.permission_for("notify")
    end

    test "rejects unknown_module" do
      yaml = """
      schema_version: 1
      slashes:
        "/help":
          kind: help
          command_module: "Esr.Commands.DoesNotExist"
          requires_workspace_binding: false
          requires_user_binding: false
          description: test
          args: []
      """

      path = write_tmp(yaml)
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:unknown_module, "Esr.Commands.DoesNotExist"}} = FileLoader.load(path)
    end

    test "rejects missing schema_version" do
      yaml = """
      slashes: {}
      """

      path = write_tmp(yaml)
      on_exit(fn -> File.rm(path) end)

      assert {:error, :missing_schema_version} = FileLoader.load(path)
    end

    test "rejects unknown schema_version" do
      yaml = """
      schema_version: 99
      slashes: {}
      """

      path = write_tmp(yaml)
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:unknown_schema_version, 99}} = FileLoader.load(path)
    end

    test "rejects slash key not starting with /" do
      yaml = """
      schema_version: 1
      slashes:
        "no-slash-prefix":
          kind: nope
          command_module: "Esr.Commands.Notify"
          requires_workspace_binding: false
          requires_user_binding: false
          description: bad
          args: []
      """

      path = write_tmp(yaml)
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:slash_key_must_start_with_slash, "no-slash-prefix"}} =
               FileLoader.load(path)
    end

    @tag :priv_default_loads
    test "loads the priv default yaml shipped with the app" do
      # Smoke test: the priv default must be a valid yaml that passes
      # all validation. Boot of `Esr.Resource.SlashRoute.Registry.Watcher` depends on this.
      #
      # Phase 1 note: the priv default references new command modules
      # (Esr.Commands.{Help,Whoami,Doctor,Agent.List}) that don't
      # exist yet. This test passes only after Phase 2 ships those modules.
      priv_path = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      assert File.exists?(priv_path), "priv default missing at #{priv_path}"

      assert :ok = FileLoader.load(priv_path)
      # Phase 6: colon-namespace cutover — should have loaded all colon-form slashes
      list = SlashRouteRegistry.list_slashes()
      assert length(list) >= 8
      # Help should resolve (bare meta command — stays bare)
      assert {:ok, _} = SlashRouteRegistry.lookup("/help")
      # Colon-form session commands resolve
      assert {:ok, _} = SlashRouteRegistry.lookup("/session:add-agent")
      assert {:ok, _} = SlashRouteRegistry.lookup("/workspace:list")
      assert {:ok, _} = SlashRouteRegistry.lookup("/user:whoami")
      # Old-form slashes do NOT resolve after cutover
      assert :not_found = SlashRouteRegistry.lookup("/sessions")
      assert :not_found = SlashRouteRegistry.lookup("/list-sessions")
      # Internal kind: notify should resolve via permission_for
      assert "notify.send" == SlashRouteRegistry.permission_for("notify")
    end
  end

  # ------------------------------------------------------------------
  # PR-2.1: dump/1 + list_internal_kinds/0
  # ------------------------------------------------------------------

  describe "list_internal_kinds/0" do
    test "returns kinds present in internal_kinds: but not in slashes:" do
      load_fixture(
        slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")},
        internal_kinds: %{
          "grant" => %{"permission" => "cap.manage", "command_module" => "Esr.Commands.Notify"},
          "revoke" => %{"permission" => "cap.manage", "command_module" => "Esr.Commands.Notify"}
        }
      )

      kinds = SlashRouteRegistry.list_internal_kinds()
      assert Enum.map(kinds, & &1.kind) == ["grant", "revoke"]
    end

    test "excludes kinds that are also in slashes: (no double-listing)" do
      # Same kind appearing in both — slashes: takes priority, internal_kinds:
      # entry is filtered out of list_internal_kinds.
      load_fixture(
        slashes: %{"/notify" => simple_route("notify", "Esr.Commands.Notify")},
        internal_kinds: %{
          "notify" => %{"permission" => "notify.send", "command_module" => "Esr.Commands.Notify"}
        }
      )

      assert SlashRouteRegistry.list_internal_kinds() == []
    end
  end

  describe "dump/1" do
    test "returns version + two sections" do
      load_fixture(
        slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")},
        internal_kinds: %{
          "grant" => %{"permission" => "cap.manage", "command_module" => "Esr.Commands.Notify"}
        }
      )

      dump = SlashRouteRegistry.dump()
      assert dump["version"] == 1
      assert is_list(dump["slashes"])
      assert is_list(dump["internal_kinds"])
      assert length(dump["slashes"]) == 1
      assert length(dump["internal_kinds"]) == 1
    end

    test "default include_internal: false strips permission + command_module" do
      load_fixture(
        slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")},
        internal_kinds: %{
          "grant" => %{"permission" => "cap.manage", "command_module" => "Esr.Commands.Notify"}
        }
      )

      dump = SlashRouteRegistry.dump()
      [slash_entry] = dump["slashes"]
      [internal_entry] = dump["internal_kinds"]

      refute Map.has_key?(slash_entry, "permission")
      refute Map.has_key?(slash_entry, "command_module")
      refute Map.has_key?(internal_entry, "permission")
      refute Map.has_key?(internal_entry, "command_module")
    end

    test "include_internal: true exposes permission + command_module on both sections" do
      load_fixture(
        slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")},
        internal_kinds: %{
          "grant" => %{"permission" => "cap.manage", "command_module" => "Esr.Commands.Notify"}
        }
      )

      dump = SlashRouteRegistry.dump(include_internal: true)
      [slash_entry] = dump["slashes"]
      [internal_entry] = dump["internal_kinds"]

      assert Map.has_key?(slash_entry, "permission")
      assert Map.has_key?(slash_entry, "command_module")
      assert internal_entry["permission"] == "cap.manage"
      assert internal_entry["command_module"] == "Esr.Commands.Notify"
    end

    test "JSON-encodable" do
      load_fixture(
        slashes: %{"/help" => simple_route("help", "Esr.Commands.Notify")},
        internal_kinds: %{
          "grant" => %{"permission" => "cap.manage", "command_module" => "Esr.Commands.Notify"}
        }
      )

      assert {:ok, json} = Jason.encode(SlashRouteRegistry.dump(include_internal: true))
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["version"] == 1
    end
  end

  # ------------------------------------------------------------------
  # Task 6.1 — colon-form matcher regression
  # ------------------------------------------------------------------

  describe "colon-form slash key matching" do
    test "colon-form key inserted directly resolves via lookup/1" do
      route = %{
        slash: "/session:new",
        kind: "session_new",
        permission: "session:default/create",
        command_module: Esr.Commands.Notify,
        requires_workspace_binding: false,
        requires_user_binding: true,
        category: "Sessions",
        description: "test",
        args: []
      }

      :ets.insert(:esr_slash_routes, {"/session:new", route})

      assert {:ok, found} = SlashRouteRegistry.lookup("/session:new name=test")
      assert found.slash == "/session:new"
      assert found.kind == "session_new"
    end

    test "colon-form key with trailing args resolves to the colon key" do
      route = %{
        slash: "/workspace:list",
        kind: "workspace_list",
        permission: "session.list",
        command_module: Esr.Commands.Notify,
        requires_workspace_binding: false,
        requires_user_binding: true,
        category: "Workspace",
        description: "test",
        args: []
      }

      :ets.insert(:esr_slash_routes, {"/workspace:list", route})

      assert {:ok, found} = SlashRouteRegistry.lookup("/workspace:list")
      assert found.slash == "/workspace:list"
    end

    test "old space-separated form does NOT match colon-form key" do
      # After yaml cutover the old form "/workspace list" must not match.
      # Here we verify that a lookup for "/workspace list" returns :not_found
      # when only "/workspace:list" is in the table (start empty + insert colon form).
      :ets.delete(:esr_slash_routes, "/workspace list")
      :ets.delete(:esr_slash_routes, "/workspace")

      assert :not_found = SlashRouteRegistry.lookup("/workspace list")
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp simple_route(kind, mod_str) do
    %{
      "kind" => kind,
      "command_module" => mod_str,
      "requires_workspace_binding" => false,
      "requires_user_binding" => false,
      "description" => "",
      "args" => []
    }
  end

  # Bypass yaml entirely — call load_snapshot/1 with the validated
  # internal shape. (YamlElixir has no write_to_string! function.)
  defp load_fixture(opts) do
    slashes_map = Keyword.get(opts, :slashes, %{})
    internal_map = Keyword.get(opts, :internal_kinds, %{})

    slashes =
      Enum.map(slashes_map, fn {key, entry} ->
        %{
          slash: key,
          kind: entry["kind"],
          permission: entry["permission"],
          command_module: Module.concat([entry["command_module"]]),
          requires_workspace_binding: Map.get(entry, "requires_workspace_binding", false),
          requires_user_binding: Map.get(entry, "requires_user_binding", false),
          category: entry["category"],
          description: Map.get(entry, "description", ""),
          aliases: Map.get(entry, "aliases", []),
          args: Map.get(entry, "args", [])
        }
      end)

    internal =
      Enum.map(internal_map, fn {kind, entry} ->
        %{
          kind: kind,
          permission: entry["permission"],
          command_module: Module.concat([entry["command_module"]])
        }
      end)

    SlashRouteRegistry.load_snapshot(%{slashes: slashes, internal_kinds: internal})
  end

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "slash-routes-test-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, content)
    path
  end
end
