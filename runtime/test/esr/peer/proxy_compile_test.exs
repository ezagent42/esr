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
end
