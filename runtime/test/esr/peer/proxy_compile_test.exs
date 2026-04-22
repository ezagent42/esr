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
end
