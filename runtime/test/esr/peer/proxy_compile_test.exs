defmodule Esr.Peer.ProxyCompileTest do
  use ExUnit.Case, async: false

  test "Peer.Proxy module rejects handle_call/3 at compile time" do
    ast =
      quote do
        defmodule BadProxy1 do
          use Esr.Peer.Proxy
          def forward(_msg, _ctx), do: :ok
          def handle_call(_msg, _from, state), do: {:reply, :ok, state}
        end
      end

    assert_raise CompileError, ~r/Peer\.Proxy .* cannot define stateful callbacks/, fn ->
      Code.compile_quoted(ast)
    end
  end

  test "Peer.Proxy module rejects handle_cast/2 at compile time" do
    ast =
      quote do
        defmodule BadProxy2 do
          use Esr.Peer.Proxy
          def forward(_msg, _ctx), do: :ok
          def handle_cast(_msg, state), do: {:noreply, state}
        end
      end

    assert_raise CompileError, ~r/Peer\.Proxy .* cannot define stateful callbacks/, fn ->
      Code.compile_quoted(ast)
    end
  end

  test "Peer.Proxy module compiles fine with only forward/2" do
    ast =
      quote do
        defmodule GoodProxy do
          use Esr.Peer.Proxy
          def forward(_msg, _ctx), do: :ok
        end
      end

    assert [{GoodProxy, _}] = Code.compile_quoted(ast)
  end

  test "Peer.Proxy module with @required_cap injects a cap-check wrapper around forward/2" do
    ast =
      quote do
        defmodule CapProxy do
          use Esr.Peer.Proxy
          @required_cap "workspace:*/msg.send"
          def forward(_msg, ctx), do: {:ok, ctx.test_tag}
        end
      end

    assert [{mod, _}] = Code.compile_quoted(ast)

    # Inject a fake Capabilities.has?/2 via a test-mode override.
    Process.put(:esr_cap_test_override, fn _pid, _perm -> false end)

    assert {:drop, :cap_denied} = mod.forward(:hi, %{principal_id: "p1", test_tag: :ok})

    Process.put(:esr_cap_test_override, fn _pid, _perm -> true end)
    assert {:ok, :ok} = mod.forward(:hi, %{principal_id: "p1", test_tag: :ok})
  after
    Process.delete(:esr_cap_test_override)
  end

  test "Peer.Proxy module without @required_cap compiles and forwards directly" do
    ast =
      quote do
        defmodule NoCapProxy do
          use Esr.Peer.Proxy
          def forward(msg, _ctx), do: {:ok, msg}
        end
      end

    assert [{mod, _}] = Code.compile_quoted(ast)
    assert {:ok, :hello} = mod.forward(:hello, %{})
  end

  describe "@required_cap with ctx.session_process_pid (P3-3a)" do
    # These tests exercise the per-Session local grants projection path
    # introduced in P3-3a. The Peer.Proxy cap-check wrapper prefers
    # SessionProcess.has?/2 (via the process pid carried in ctx) over
    # the global Esr.Capabilities.has?/2. That means the outcome of a
    # forward/2 call depends on the session-local grants map, NOT on
    # the global ETS table — admin-plane writes can't contend with
    # data-plane reads, and each session's grants are independent.

    setup do
      assert is_pid(Process.whereis(Esr.Session.Registry))

      if Process.whereis(Esr.Capabilities.Grants) == nil do
        start_supervised!(Esr.Capabilities.Grants)
      end

      :ok
    end

    test "cap check uses SessionProcess.has?/2 when ctx.session_process_pid is alive" do
      ast =
        quote do
          defmodule SessionLocalProxy do
            use Esr.Peer.Proxy
            @required_cap "workspace:proj-p/msg.send"
            def forward(_msg, ctx), do: {:ok, ctx.test_tag}
          end
        end

      assert [{mod, _}] = Code.compile_quoted(ast)

      # Seed the global Grants with a DIFFERENT grant than what the
      # session-local projection will have. The session's local map
      # wins, proving the proxy went through the per-session path.
      :ok = Esr.Capabilities.Grants.load_snapshot(%{"p_proxy_local" => []})

      {:ok, _sup} =
        Esr.Session.start_link(%{
          session_id: "proxy-sp-1",
          agent_name: "cc",
          dir: "/tmp/pp",
          chat_thread_key: %{chat_id: "oc_p", thread_id: "om_p"},
          metadata: %{principal_id: "p_proxy_local"}
        })

      [{sp_pid, _}] =
        Registry.lookup(Esr.Session.Registry, {:session_process, "proxy-sp-1"})

      # With no grants for p_proxy_local, the local projection denies.
      assert {:drop, :cap_denied} =
               mod.forward(:hi, %{
                 principal_id: "p_proxy_local",
                 session_process_pid: sp_pid,
                 test_tag: :ok
               })

      # Now load a matching grant — the broadcast refreshes the
      # session's local projection, and the forward succeeds.
      :ok =
        Esr.Capabilities.Grants.load_snapshot(%{
          "p_proxy_local" => ["workspace:proj-p/msg.send"]
        })

      # Wait a tick for the PubSub broadcast → handle_info → state update.
      # A synchronous GenServer.call to the SessionProcess after the
      # broadcast is ordered behind the handle_info.
      Process.sleep(50)

      assert {:ok, :ok} =
               mod.forward(:hi, %{
                 principal_id: "p_proxy_local",
                 session_process_pid: sp_pid,
                 test_tag: :ok
               })
    end

    test "cap check falls back to Esr.Capabilities.has?/2 when no session_process_pid" do
      ast =
        quote do
          defmodule GlobalFallbackProxy do
            use Esr.Peer.Proxy
            @required_cap "workspace:proj-g/msg.send"
            def forward(_msg, ctx), do: {:ok, ctx.test_tag}
          end
        end

      assert [{mod, _}] = Code.compile_quoted(ast)

      # No session_process_pid in ctx → falls back to global has?/2.
      :ok =
        Esr.Capabilities.Grants.load_snapshot(%{
          "p_proxy_global" => ["workspace:proj-g/msg.send"]
        })

      assert {:ok, :ok} =
               mod.forward(:hi, %{principal_id: "p_proxy_global", test_tag: :ok})

      :ok = Esr.Capabilities.Grants.load_snapshot(%{"p_proxy_global" => []})

      assert {:drop, :cap_denied} =
               mod.forward(:hi, %{principal_id: "p_proxy_global", test_tag: :ok})
    end
  end
end
