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

    # Phase B regression (resource-typed grammar second-review #2):
    # /session:switch returns %{"session_id" => sid, "switched" => true};
    # the generic {"session_id"} clause was shadowing it and rendering
    # "session started: <sid>" — actively misleading (operator could
    # think a NEW session was spawned). Discriminating clause must come
    # before the generic one in the file.
    test "format_result for /session:switch success renders 'switched' message" do
      result = {:ok, %{"session_id" => "abc-123", "switched" => true}}
      rendered = ChatPid.format_result(result)
      assert rendered =~ "switched"
      assert rendered =~ "abc-123"
      refute rendered =~ "started"
    end

    test "format_result for /session:new success still renders 'started' message" do
      # Negative: ensure the new clause didn't accidentally consume
      # non-switch shapes (no "switched" field).
      result = {:ok, %{"session_id" => "xyz-456"}}
      rendered = ChatPid.format_result(result)
      assert rendered =~ "started"
      assert rendered =~ "xyz-456"
    end

    # 2026-05-11 user-reported regression: /agent:list returns
    # %{"chat_id" => _, "session_id" => sid, "agents" => [...]}; the
    # generic {"session_id"} clause was shadowing it and rendering
    # "session started: <sid>" — operator saw no agent list.
    # Same subset-match bug class as /session:switch above.
    test "format_result for /agent:list with agents renders the list" do
      result =
        {:ok,
         %{
           "chat_id" => "c1",
           "session_id" => "sid-1",
           "agents" => [
             %{
               "name" => "helper",
               "type" => "cc",
               "actor_ids" => %{"cc" => "cc-1", "pty" => "pty-1"}
             }
           ]
         }}

      rendered = ChatPid.format_result(result)
      assert rendered =~ "helper"
      assert rendered =~ "cc"
      assert rendered =~ "sid-1"
      refute rendered =~ "session started"
    end

    test "format_result for /agent:list with no agents renders 'no agents' hint" do
      result = {:ok, %{"chat_id" => "c", "session_id" => "sid-2", "agents" => []}}
      rendered = ChatPid.format_result(result)
      assert rendered =~ "no agents"
      assert rendered =~ "sid-2"
      assert rendered =~ "/agent:add"
      refute rendered =~ "session started"
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

    # Walkthrough-4 #348. Pre-fix `format_result/1` rendered any
    # `{:error, %{"type" => _, "message" => _}}` as just `"error: <type>"`
    # — the canonical interpolated message produced by
    # `Esr.Commands.Render.error/3` was silently dropped on the chat
    # path. Operators saw `error: session_start_failed` with no idea
    # what failed and had to drop to CLI to see the full details.
    test "format_result with {:error, type + message} prepends type AND keeps the message body (#348)" do
      result =
        {:error,
         %{
           "type" => "no_workspace_target",
           "message" =>
             "no explicit workspace= and no chat-current binding and no user-default workspace"
         }}

      rendered = ChatPid.format_result(result)

      assert rendered =~ "error: no_workspace_target",
             "type tag must still be visible for grep / log matching"

      assert rendered =~ "no explicit workspace=",
             "message body must be appended so operator sees the actionable detail"
    end

    test "format_result with {:error, type only} (no message) still uses type-only render" do
      # Backwards-compat: commands that emit type without an explicit
      # message (rare, but legal) keep the short render.
      rendered = ChatPid.format_result({:error, %{"type" => "internal_error"}})
      assert rendered == "error: internal_error"
    end

    test "respond delivers the multi-line message body to subscriber" do
      ref = make_ref()

      assert :ok =
               ChatPid.respond(
                 self(),
                 {:error,
                  %{
                    "type" => "session_start_failed",
                    "message" => "session start failed: details_here"
                  }},
                 ref
               )

      assert_receive {:reply, text, ^ref}
      assert text =~ "details_here"
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

      command = %{"id" => id, "kind" => "feishu_notify", "args" => %{"text" => "hi"}}
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

      command = %{"id" => id, "kind" => "feishu_notify", "args" => %{}}
      target = %{id: id, command: command}

      assert :ok =
               QueueFile.respond(
                 target,
                 {:error, %{"type" => "unauthorized", "kind" => "feishu_notify"}},
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

      command = %{"id" => id, "kind" => "feishu_notify", "args" => %{}}
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
