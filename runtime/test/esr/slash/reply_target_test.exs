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

  describe "QueueFile (PR-2.3b — real impl)" do
    setup do
      unique = System.unique_integer([:positive])
      tmp = Path.join(System.tmp_dir!(), "qf_rt_#{unique}")
      File.mkdir_p!(Path.join(tmp, "default"))

      for sub <- ["pending", "processing", "completed", "failed"] do
        File.mkdir_p!(Path.join([tmp, "default", "admin_queue", sub]))
      end

      prev_home = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "default")

      on_exit(fn ->
        if prev_home,
          do: System.put_env("ESRD_HOME", prev_home),
          else: System.delete_env("ESRD_HOME")

        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "writes {:ok, _} result to completed/<id>.yaml" do
      id = "qf-ok-#{System.unique_integer([:positive])}"
      processing = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      File.write!(processing, "id: #{id}\n")

      command = %{"id" => id, "kind" => "notify", "args" => %{"text" => "hi"}}
      target = %{id: id, command: command}

      assert :ok =
               QueueFile.respond(target, {:ok, %{"echoed" => "hi"}}, make_ref())

      out = Path.join(Esr.Paths.admin_queue_dir(), "completed/#{id}.yaml")
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["result"]["ok"] == true
      assert parsed["result"]["echoed"] == "hi"
    end

    test "writes {:error, _} result to failed/<id>.yaml" do
      id = "qf-err-#{System.unique_integer([:positive])}"
      processing = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      File.write!(processing, "id: #{id}\n")

      command = %{"id" => id, "kind" => "notify", "args" => %{}}
      target = %{id: id, command: command}

      assert :ok =
               QueueFile.respond(
                 target,
                 {:error, %{"type" => "unauthorized", "kind" => "notify"}},
                 make_ref()
               )

      out = Path.join(Esr.Paths.admin_queue_dir(), "failed/#{id}.yaml")
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["result"]["ok"] == false
      assert parsed["result"]["type"] == "unauthorized"
    end

    test "writes {:text, _} synthetic error to failed/<id>.yaml" do
      id = "qf-text-#{System.unique_integer([:positive])}"
      processing = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      File.write!(processing, "id: #{id}\n")

      command = %{"id" => id, "kind" => "notify", "args" => %{}}
      target = %{id: id, command: command}

      assert :ok =
               QueueFile.respond(target, {:text, "command timed out (>5s)"}, make_ref())

      out = Path.join(Esr.Paths.admin_queue_dir(), "failed/#{id}.yaml")
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["result"]["error"] =~ "timed out"
    end

    test "redaction applies to args.token / args.secret / args.app_secret" do
      id = "qf-redact-#{System.unique_integer([:positive])}"
      processing = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      File.write!(processing, "id: #{id}\n")

      command = %{
        "id" => id,
        "kind" => "register_adapter",
        "args" => %{"name" => "app1", "token" => "very-secret-abc"}
      }

      target = %{id: id, command: command}

      assert :ok = QueueFile.respond(target, {:ok, %{"registered" => true}}, make_ref())

      out = Path.join(Esr.Paths.admin_queue_dir(), "completed/#{id}.yaml")
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["args"]["token"] == "[redacted_post_exec]"
      assert parsed["args"]["name"] == "app1"
    end
  end

  describe "WS stub (PR-2.8 placeholder)" do
    test "returns {:error, :not_implemented}" do
      ref = make_ref()
      assert {:error, :not_implemented} = WS.respond(%{topic: "t"}, {:text, "_"}, ref)
    end
  end
end
