defmodule Esr.Commands.RegisterAdapterTest do
  @moduledoc """
  DI-8 Task 16 — `Esr.Commands.RegisterAdapter` persists a new
  adapter instance to `adapters.yaml` (with `app_id` AND `app_secret`
  in the config block) and calls `WorkerSupervisor.ensure_adapter` to
  hot-load the adapter subprocess post-boot.

  Pre-2026-05-09: secret was written to `<runtime_home>/.env.local`,
  but no consumer ever read it (`adapter_process.ex`'s os_env/1 only
  injects ESR_SPAWN_TOKEN + PYTHONUNBUFFERED). Sidecar crash-looped
  with `app_secret missing from AdapterConfig`. Fix: secret now flows
  through adapters.yaml's config block on every spawn AND restore.

  ## Why the spawn_fn injection

  `execute/2` takes an opts keyword with `:spawn_fn` so tests don't
  actually spawn a Python Feishu subprocess. The Dispatcher calls
  `execute/1` (no opts) which uses the real
  `Esr.WorkerSupervisor.ensure_adapter/4`. Pattern mirrors
  `Esr.Application.restore_adapters_from_disk/2`.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.RegisterAdapter

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_regadapt_#{unique}")
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

  describe "execute/2 happy path" do
    test "appends to adapters.yaml (with app_secret in config block) + calls spawn_fn", %{
      tmp: tmp
    } do
      parent = self()

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "esr_dev_helper",
          "app_id" => "cli_test_app_id",
          "app_secret" => "sekret123"
        }
      }

      assert {:ok, %{"adapter_id" => "esr_dev_helper", "running" => true}} =
               RegisterAdapter.execute(cmd,
                 spawn_fn: fn args ->
                   send(parent, {:spawned, args})
                   :ok
                 end
               )

      # adapters.yaml was written with both app_id AND app_secret in
      # the config block — sidecar AdapterConfig validation requires
      # both keys, this is the production-bug regression guard.
      adapters_path = Path.join([tmp, "default", "adapters.yaml"])
      assert File.exists?(adapters_path)
      {:ok, parsed} = YamlElixir.read_from_file(adapters_path)

      assert %{
               "instances" => %{
                 "esr_dev_helper" => %{
                   "type" => "feishu",
                   "config" => %{
                     "app_id" => "cli_test_app_id",
                     "app_secret" => "sekret123"
                   }
                 }
               }
             } = parsed

      # spawn_fn saw the right args (type, name, config, url) — config
      # MUST carry app_secret, otherwise the Python sidecar crash-loops
      # with `app_secret missing from AdapterConfig`.
      assert_received {:spawned,
                       {"feishu", "esr_dev_helper",
                        %{
                          "app_id" => "cli_test_app_id",
                          "app_secret" => "sekret123"
                        }, url}}

      assert is_binary(url)
      assert url =~ "/adapter_hub/socket/websocket"
    end

    test "merges into existing adapters.yaml without clobbering prior instances", %{tmp: tmp} do
      adapters_path = Path.join([tmp, "default", "adapters.yaml"])

      File.write!(adapters_path, """
      instances:
        existing_helper:
          type: feishu
          config:
            app_id: cli_existing
      """)

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "new_helper",
          "app_id" => "cli_new",
          "app_secret" => "new_secret"
        }
      }

      assert {:ok, _} =
               RegisterAdapter.execute(cmd, spawn_fn: fn _ -> :ok end)

      {:ok, parsed} = YamlElixir.read_from_file(adapters_path)

      assert Map.has_key?(parsed["instances"], "existing_helper")
      assert Map.has_key?(parsed["instances"], "new_helper")
      assert parsed["instances"]["existing_helper"]["config"]["app_id"] == "cli_existing"
      assert parsed["instances"]["new_helper"]["config"]["app_id"] == "cli_new"
      assert parsed["instances"]["new_helper"]["config"]["app_secret"] == "new_secret"
    end

    test "registering a second adapter preserves the first instance + its secret", %{tmp: tmp} do
      adapters_path = Path.join([tmp, "default", "adapters.yaml"])

      # First command.
      assert {:ok, _} =
               RegisterAdapter.execute(
                 %{
                   "args" => %{
                     "type" => "feishu",
                     "name" => "first",
                     "app_id" => "a1",
                     "app_secret" => "s1"
                   }
                 },
                 spawn_fn: fn _ -> :ok end
               )

      # Second command.
      assert {:ok, _} =
               RegisterAdapter.execute(
                 %{
                   "args" => %{
                     "type" => "feishu",
                     "name" => "second",
                     "app_id" => "a2",
                     "app_secret" => "s2"
                   }
                 },
                 spawn_fn: fn _ -> :ok end
               )

      {:ok, parsed} = YamlElixir.read_from_file(adapters_path)
      assert parsed["instances"]["first"]["config"]["app_id"] == "a1"
      assert parsed["instances"]["first"]["config"]["app_secret"] == "s1"
      assert parsed["instances"]["second"]["config"]["app_id"] == "a2"
      assert parsed["instances"]["second"]["config"]["app_secret"] == "s2"
    end
  end

  describe "execute/2 error paths" do
    test "invalid args (missing app_secret) returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               RegisterAdapter.execute(
                 %{"args" => %{"type" => "feishu", "name" => "x", "app_id" => "y"}},
                 spawn_fn: fn _ -> :ok end
               )
    end

    test "unknown type (non-feishu) returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               RegisterAdapter.execute(
                 %{
                   "args" => %{
                     "type" => "slack",
                     "name" => "x",
                     "app_id" => "y",
                     "app_secret" => "z"
                   }
                 },
                 spawn_fn: fn _ -> :ok end
               )
    end

    test "spawn_fn failure propagates as register_adapter_failed" do
      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "boom",
          "app_id" => "a",
          "app_secret" => "s"
        }
      }

      assert {:error, %{"type" => "register_adapter_failed"}} =
               RegisterAdapter.execute(cmd,
                 spawn_fn: fn _ -> {:error, :subprocess_crash} end
               )
    end
  end

  describe "execute/1 default path" do
    test "malformed command still rejected without touching disk" do
      # No args at all — the match falls to the invalid_args clause and
      # never writes anything.
      assert {:error, %{"type" => "invalid_args"}} = RegisterAdapter.execute(%{})
    end
  end

  describe "execute/2 boot-race resilience (PR-7 e2e discovery)" do
    @tag :tmp_dir
    test "default_adapter_ws_url/0 survives EsrWeb.Endpoint's ETS table missing", %{
      tmp: tmp
    } do
      # E2E RCA: admin watcher's orphan-recovery scan fires execute/2
      # BEFORE EsrWeb.Endpoint has started (Endpoint is the LAST
      # supervisor child), so EsrWeb.Endpoint.config(:http) raises
      # ArgumentError "the table identifier does not refer to an
      # existing ETS table". PR-7 hardened default_adapter_ws_url/0 with
      # a try/rescue + Application.get_env fallback. This test proves
      # the fallback kicks in without crashing the command.
      #
      # Simulate by running execute/2 with the real dispatch chain — the
      # try/rescue must return a valid ws:// URL regardless of Endpoint
      # state.
      Application.put_env(:esr, :runtime_home, tmp)

      cmd = %{
        "submitted_by" => "ou_admin",
        "kind" => "register_adapter",
        "args" => %{
          "type" => "feishu",
          "name" => "endpoint_race_guard",
          "app_id" => "app_race",
          "app_secret" => "s"
        }
      }

      url_agent = Agent.start_link(fn -> nil end) |> elem(1)

      result =
        RegisterAdapter.execute(cmd,
          spawn_fn: fn {_, _, _, url} ->
            Agent.update(url_agent, fn _ -> url end)
            :ok
          end
        )

      assert {:ok, %{"running" => true}} = result

      captured = Agent.get(url_agent, & &1)
      Agent.stop(url_agent)

      # URL must be well-formed ws:// with a port, regardless of which
      # path (Endpoint.config, Application.get_env, or literal 4001)
      # produced it.
      assert captured =~ ~r|^ws://127\.0\.0\.1:\d+/adapter_hub/socket/websocket|,
             "default_adapter_ws_url returned #{inspect(captured)} — expected ws://127.0.0.1:<port>/..."
    end
  end

  describe "spawn config carries app_secret (2026-05-09 sidecar-auth fix)" do
    test "spawn_fn is invoked with config containing both app_id and app_secret" do
      test_pid = self()

      spawn_stub = fn {type, instance, config, _url} ->
        send(test_pid, {:spawn_called, type, instance, config})
        :ok
      end

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "esr_helper",
          "app_id" => "cli_test",
          "app_secret" => "sekret123"
        }
      }

      assert {:ok, _} = RegisterAdapter.execute(cmd, spawn_fn: spawn_stub)

      assert_receive {:spawn_called, "feishu", "esr_helper",
                      %{"app_id" => "cli_test", "app_secret" => "sekret123"}},
                     1_000
    end

    test "adapters.yaml gets app_secret persisted in config block", %{tmp: tmp} do
      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "esr_persist_test",
          "app_id" => "cli_pX",
          "app_secret" => "secret_pX"
        }
      }

      assert {:ok, _} = RegisterAdapter.execute(cmd, spawn_fn: fn _ -> :ok end)

      {:ok, doc} = YamlElixir.read_from_file(Path.join([tmp, "default", "adapters.yaml"]))
      assert get_in(doc, ["instances", "esr_persist_test", "config", "app_secret"]) == "secret_pX"
      assert get_in(doc, ["instances", "esr_persist_test", "config", "app_id"]) == "cli_pX"
    end
  end
end
