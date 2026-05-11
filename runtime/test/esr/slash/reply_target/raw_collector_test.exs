defmodule Esr.Slash.ReplyTarget.RawCollectorTest do
  @moduledoc """
  Unit tests for `Esr.Slash.ReplyTarget.RawCollector` — the raw-result
  forwarding impl used by the `submit_slash` MCP tool path (PR-4).
  """

  use ExUnit.Case, async: true

  alias Esr.Slash.ReplyTarget.RawCollector

  describe "respond/3" do
    test "forwards {:ok, result} to caller as {:slash_raw, ref, {:ok, result}}" do
      ref = make_ref()
      slash_ref = make_ref()

      assert :ok =
               RawCollector.respond(
                 %{caller: self(), ref: ref},
                 {:ok, %{x: 1}},
                 slash_ref
               )

      assert_receive {:slash_raw, ^ref, {:ok, %{x: 1}}}, 100
    end

    test "forwards {:error, reason} to caller as {:slash_raw, ref, {:error, reason}}" do
      ref = make_ref()
      slash_ref = make_ref()

      assert :ok =
               RawCollector.respond(
                 %{caller: self(), ref: ref},
                 {:error, :nope},
                 slash_ref
               )

      assert_receive {:slash_raw, ^ref, {:error, :nope}}, 100
    end

    test "wraps non-tagged result as {:ok, result}" do
      ref = make_ref()
      slash_ref = make_ref()

      assert :ok =
               RawCollector.respond(
                 %{caller: self(), ref: ref},
                 %{"text" => "ok"},
                 slash_ref
               )

      assert_receive {:slash_raw, ^ref, {:ok, %{"text" => "ok"}}}, 100
    end

    test "delivers to a different caller pid (not just self())" do
      ref = make_ref()
      slash_ref = make_ref()
      parent = self()

      child =
        spawn(fn ->
          receive do
            {:slash_raw, ^ref, _} = msg -> send(parent, {:got, msg})
          after
            500 -> send(parent, :timeout)
          end
        end)

      :ok = RawCollector.respond(%{caller: child, ref: ref}, {:ok, %{}}, slash_ref)
      assert_receive {:got, {:slash_raw, ^ref, {:ok, %{}}}}, 200
    end

    test "is registered as an Esr.Slash.ReplyTarget behaviour impl" do
      behaviours =
        RawCollector.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Esr.Slash.ReplyTarget in behaviours
    end
  end
end
