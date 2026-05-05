defmodule Esr.Slash.ReplyTargetTest do
  @moduledoc """
  Tests for the dependency-inversion boundary at
  `Esr.Slash.ReplyTarget`. Each impl is tested in isolation; the
  behaviour-level helpers (`normalize/1`, `dispatch/3`) are tested
  separately.

  Stubs (QueueFile, WS) are exercised only to confirm the
  `{:error, :not_implemented}` contract — full coverage lands with
  PR-2.3a (QueueFile) and PR-2.8 (WS).
  """

  use ExUnit.Case, async: true

  alias Esr.Slash.ReplyTarget
  alias Esr.Slash.ReplyTarget.{ChatPid, IO, QueueFile, WS}

  describe "ReplyTarget.normalize/1" do
    test "wraps a bare pid as {ChatPid, pid}" do
      pid = self()
      assert {ChatPid, ^pid} = ReplyTarget.normalize(pid)
    end

    test "passes through {module, target} unchanged" do
      target = {QueueFile, %{queue_id: "abc"}}
      assert ^target = ReplyTarget.normalize(target)
    end

    test "raises on bad shape" do
      assert_raise ArgumentError, fn -> ReplyTarget.normalize(:bogus) end
      assert_raise ArgumentError, fn -> ReplyTarget.normalize("string") end
    end
  end

  describe "ReplyTarget.dispatch/3 — error containment" do
    test "logs and returns {:error, _} when impl raises" do
      defmodule Esr.Slash.ReplyTarget.RaisingFake do
        @behaviour Esr.Slash.ReplyTarget
        @impl true
        def respond(_target, _result, _ref), do: raise("boom")
      end

      ref = make_ref()

      assert {:error, {:respond_raised, _}} =
               ReplyTarget.dispatch(
                 {Esr.Slash.ReplyTarget.RaisingFake, :anything},
                 {:text, "hi"},
                 ref
               )
    end
  end

  describe "ChatPid impl" do
    test "respond {:text, str} sends {:reply, str, ref}" do
      ref = make_ref()
      assert :ok = ChatPid.respond(self(), {:text, "hello"}, ref)
      assert_receive {:reply, "hello", ^ref}
    end

    test "respond {:ok, %{branches: ...}} renders as 'sessions: a, b'" do
      ref = make_ref()
      assert :ok = ChatPid.respond(self(), {:ok, %{"branches" => ["main", "dev"]}}, ref)
      assert_receive {:reply, "sessions: main, dev", ^ref}
    end

    test "respond {:ok, %{text: ...}} returns text directly (Help/Whoami/Doctor)" do
      ref = make_ref()
      assert :ok = ChatPid.respond(self(), {:ok, %{"text" => "free-form output"}}, ref)
      assert_receive {:reply, "free-form output", ^ref}
    end

    test "respond {:error, %{type: 'missing_capabilities', caps: [...]}} renders error" do
      ref = make_ref()

      assert :ok =
               ChatPid.respond(
                 self(),
                 {:error, %{"type" => "missing_capabilities", "caps" => ["c1", "c2"]}},
                 ref
               )

      assert_receive {:reply, "error: missing caps — c1, c2", ^ref}
    end

    test "respond catch-all renders any term" do
      ref = make_ref()
      assert :ok = ChatPid.respond(self(), {:something, :weird}, ref)
      assert_receive {:reply, text, ^ref}
      assert text =~ "result:"
    end
  end

  describe "IO impl" do
    test "respond writes to stdio device by default (capture)" do
      ref = make_ref()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = IO.respond(:stdio, {:text, "from-cli"}, ref)
        end)

      assert output =~ "from-cli"
    end

    test "respond renders {:ok, _} via ChatPid format" do
      ref = make_ref()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   IO.respond(:stdio, {:ok, %{"text" => "hello-cli"}}, ref)
        end)

      assert output =~ "hello-cli"
    end
  end

  describe "QueueFile stub (PR-2.3a placeholder)" do
    test "returns {:error, :not_implemented}" do
      ref = make_ref()
      assert {:error, :not_implemented} = QueueFile.respond(%{queue_id: "x"}, {:text, "_"}, ref)
    end
  end

  describe "WS stub (PR-2.8 placeholder)" do
    test "returns {:error, :not_implemented}" do
      ref = make_ref()
      assert {:error, :not_implemented} = WS.respond(%{topic: "t"}, {:text, "_"}, ref)
    end
  end
end
