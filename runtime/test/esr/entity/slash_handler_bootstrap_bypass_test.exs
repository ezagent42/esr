defmodule Esr.Entity.SlashHandlerBootstrapBypassTest do
  @moduledoc """
  Tests for the `"system:bootstrap"` cap-bypass at the
  `Esr.Entity.SlashHandler` `:dispatch_command` cap-gate.

  Spec: docs/superpowers/specs/2026-05-09-zero-config-bootstrap.md § 3.2.

  Bypass fires only when ALL three conditions hold:

    1. `submitted_by == "system:bootstrap"`
    2. `kind in @bootstrap_allowed_kinds` (initial: `["user_add"]`)
    3. `Esr.Resource.Capability.Grants.any_admin?/0 == false`

  Any one missing → unauthorized (normal cap-check denies). Each test
  flips one condition off and asserts the expected outcome.

  Verification strategy mirrors `notify_test.exs` — direct cast via
  `SlashHandler.dispatch_command/2` with a `pid` reply target so the
  result reaches the test process via `{:reply, text, ref}` (or
  `{:directive, ...}` is irrelevant here since command_module is fake).

  We register a fake command_module for the test kinds via
  `SlashRoute.Registry.load_snapshot/1` to keep the test focused on the
  cap-bypass branch — no real `Esr.Commands.User.Add` side-effects.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.SlashHandler
  alias Esr.Resource.Capability.Grants
  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  defmodule TestEcho do
    @moduledoc "Fake command module — echo kind back so tests can pin the reply."
    def execute(%{"kind" => kind}) do
      {:ok, %{"text" => "echo:#{kind}"}}
    end
  end

  setup do
    # Make sure the dispatch engine is alive (other tests may have torn
    # down Esr.Session.Admin.Process.slash_handler_ref).
    case Esr.Session.Admin.Process.slash_handler_ref() do
      {:ok, _pid} -> :ok
      :error -> :ok = Esr.Session.Admin.bootstrap_slash_handler()
    end

    # Stand up SlashRoute.Registry if a sibling test torn it down.
    case Process.whereis(SlashRouteRegistry) do
      nil -> start_supervised!(SlashRouteRegistry)
      _ -> :ok
    end

    # Stand up Grants if not already running. Capability.Grants is
    # owned by Esr.Resource.Capability.Supervisor in production; tests
    # talk to the singleton.
    case Process.whereis(Grants) do
      nil -> start_supervised!(Grants)
      _ -> :ok
    end

    # Test routes:
    #   - "user_add" (allowed-kind for the bypass) requires "user.manage"
    #   - "register_adapter" (NOT allowed-kind) requires "adapter.manage"
    SlashRouteRegistry.load_snapshot(%{
      slashes: [],
      internal_kinds: [
        %{
          kind: "user_add",
          permission: "user.manage",
          command_module: __MODULE__.TestEcho,
          requires_workspace_binding: false,
          requires_user_binding: false,
          slash: nil,
          category: "test",
          description: "test",
          aliases: [],
          args: []
        },
        %{
          kind: "register_adapter",
          permission: "adapter.manage",
          command_module: __MODULE__.TestEcho,
          requires_workspace_binding: false,
          requires_user_binding: false,
          slash: nil,
          category: "test",
          description: "test",
          aliases: [],
          args: []
        }
      ]
    })

    on_exit(fn ->
      # Restore the priv default so cross-file tests stay green.
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
      Grants.load_snapshot(%{})
    end)

    :ok
  end

  describe "bootstrap-sentinel cap bypass (spec § 3.2)" do
    test "all 3 conditions true → bypass dispatches command" do
      # No admin in cap table.
      Grants.load_snapshot(%{})
      refute Grants.any_admin?()

      command = %{
        "id" => "01ARZBYP1",
        "kind" => "user_add",
        "submitted_by" => "system:bootstrap",
        "args" => %{"name" => "alice"}
      }

      _ref = SlashHandler.dispatch_command(command, self())

      assert_receive {:reply, text, _ref}, 2_000
      assert text =~ "echo:user_add"
    end

    test "any_admin? = true → sentinel deactivates → unauthorized" do
      # Seed an existing admin — sentinel should now be a no-op.
      Grants.load_snapshot(%{"existing-admin" => ["*"]})
      assert Grants.any_admin?()

      command = %{
        "id" => "01ARZBYP2",
        "kind" => "user_add",
        "submitted_by" => "system:bootstrap",
        "args" => %{"name" => "alice"}
      }

      _ref = SlashHandler.dispatch_command(command, self())

      assert_receive {:reply, text, _ref}, 2_000
      assert text =~ "unauthorized"
    end

    test "kind not in @bootstrap_allowed_kinds → unauthorized" do
      # Fresh state (no admin), but kind is register_adapter (not in
      # allowed list) — bypass must NOT fire.
      Grants.load_snapshot(%{})
      refute Grants.any_admin?()

      command = %{
        "id" => "01ARZBYP3",
        "kind" => "register_adapter",
        "submitted_by" => "system:bootstrap",
        "args" => %{"type" => "feishu", "name" => "x"}
      }

      _ref = SlashHandler.dispatch_command(command, self())

      assert_receive {:reply, text, _ref}, 2_000
      assert text =~ "unauthorized"
    end

    test "non-sentinel submitter + no admin → unauthorized (sanity)" do
      # No admin in cap table, but submitter is not the sentinel —
      # normal cap-check denies because ou_unknown holds nothing.
      Grants.load_snapshot(%{})
      refute Grants.any_admin?()

      command = %{
        "id" => "01ARZBYP4",
        "kind" => "user_add",
        "submitted_by" => "ou_unknown",
        "args" => %{"name" => "alice"}
      }

      _ref = SlashHandler.dispatch_command(command, self())

      assert_receive {:reply, text, _ref}, 2_000
      assert text =~ "unauthorized"
    end
  end
end
