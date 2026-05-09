defmodule Esr.Entity.SlashHandlerBarePrefixTest do
  @moduledoc """
  Tests for Phase 6 of the unified-command-grammar migration:
  bare-prefix help routing inside `Esr.Entity.SlashHandler`.

  After the registry's `lookup/1` returns `:not_found` AND the
  `@deprecated_slashes` rename map misses, SlashHandler now consults
  `Esr.Resource.SlashRoute.Registry.lookup_prefix/1` and dispatches to
  `Esr.Commands.ResourceHelp` for known resource prefixes (or emits a
  friendly error for unknown ones).

  Mirrors the boot/setup pattern from `slash_handler_dispatch_test.exs`
  — start the Registry, load a deterministic snapshot, start a fresh
  SlashHandler GenServer per test, cast `{:dispatch, env, self(), ref}`,
  and assert `{:reply, text, ref}` arrives via the ChatPid reply target.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.SlashHandler
  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  @principal "ou_bare_prefix_test"

  defmodule TestEcho do
    @moduledoc "Fake command — pins reply for routes that DO match."
    def execute(%{"kind" => kind}), do: {:ok, %{"text" => "echo:#{kind}"}}
  end

  setup do
    assert is_pid(Process.whereis(Esr.Session.Admin.Process))

    if Process.whereis(SlashRouteRegistry) == nil,
      do: start_supervised!(SlashRouteRegistry)

    SlashRouteRegistry.load_snapshot(test_routes())

    on_exit(fn ->
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
    end)

    :ok
  end

  test "/workspace dispatches to ResourceHelp and returns method listing" do
    pid = start_handler!()
    ref = make_ref()
    cast_dispatch(pid, envelope("/workspace"), self(), ref)

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "/workspace:new"
  end

  test "/workspace:help dispatches to ResourceHelp (alias)" do
    pid = start_handler!()
    ref = make_ref()
    cast_dispatch(pid, envelope("/workspace:help"), self(), ref)

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "/workspace:new"
  end

  test "bare / returns top-level resources list" do
    pid = start_handler!()
    ref = make_ref()
    cast_dispatch(pid, envelope("/"), self(), ref)

    assert_receive {:reply, text, ^ref}, 2_000
    # Top-level renderer lists each unique resource as `/<resource>`.
    assert text =~ "top-level resources"
    assert text =~ "/workspace"
  end

  test "/totallybogus returns unknown_resource hint" do
    pid = start_handler!()
    ref = make_ref()
    cast_dispatch(pid, envelope("/totallybogus"), self(), ref)

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "totallybogus"
  end

  test "/workspace:bogusmethod returns unknown_method hint mentioning resource" do
    pid = start_handler!()
    ref = make_ref()
    cast_dispatch(pid, envelope("/workspace:bogusmethod"), self(), ref)

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "bogusmethod"
    assert text =~ "/workspace"
  end

  test "deprecated /new-workspace still wins over bare-prefix routing" do
    # /new-workspace is in @deprecated_slashes → /workspace:new. The
    # rename hint must fire BEFORE lookup_prefix gets a chance, otherwise
    # operators typing the old form would get the workspace help text
    # instead of the migration nudge.
    pid = start_handler!()
    ref = make_ref()
    cast_dispatch(pid, envelope("/new-workspace"), self(), ref)

    assert_receive {:reply, text, ^ref}, 2_000
    assert text =~ "renamed"
    assert text =~ "/workspace:new"
    refute text =~ "📖 /workspace"
  end

  # ------------------------------------------------------------------
  # Helpers (mirrored from slash_handler_dispatch_test.exs)
  # ------------------------------------------------------------------

  defp start_handler!(opts \\ []) do
    {:ok, pid} =
      GenServer.start_link(
        SlashHandler,
        Map.merge(
          %{session_id: "admin", neighbors: [], proxy_ctx: %{}},
          Map.new(opts)
        )
      )

    pid
  end

  defp cast_dispatch(pid, envelope, reply_to, ref) do
    GenServer.cast(pid, {:dispatch, envelope, reply_to, ref})
  end

  defp envelope(text) do
    %{
      "principal_id" => @principal,
      "payload" => %{
        "text" => text,
        "args" => %{"content" => text}
      }
    }
  end

  defp test_routes do
    %{
      slashes: [
        route("/workspace:new", "workspace_new"),
        route("/workspace:list", "workspace_list"),
        route("/session:list", "session_list")
      ],
      internal_kinds: []
    }
  end

  defp route(slash, kind) do
    %{
      slash: slash,
      kind: kind,
      permission: nil,
      command_module: TestEcho,
      requires_workspace_binding: false,
      requires_user_binding: false,
      category: "test",
      description: "test",
      aliases: [],
      args: []
    }
  end
end
