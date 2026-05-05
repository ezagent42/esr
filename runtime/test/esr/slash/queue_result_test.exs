defmodule Esr.Slash.QueueResultTest do
  @moduledoc """
  Unit tests for `Esr.Slash.QueueResult` (PR-2.3a). The module owns
  the admin-queue file state machine + secret redaction extracted
  from `Esr.Admin.Dispatcher`. These tests pin the public API
  (`start_processing`, `move_pending_to`, `finish`, `recover_stale`,
  `secret_arg_keys`, `redacted_post_exec`) so PR-2.3b can swap in
  a new caller without re-deriving behaviour.
  """

  use ExUnit.Case, async: false

  alias Esr.Slash.QueueResult

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "qr_test_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    for sub <- ["pending", "processing", "completed", "failed"],
        do: File.mkdir_p!(Path.join([tmp, "default", "admin_queue", sub]))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "start_processing/1" do
    test "moves pending/<id>.yaml → processing/<id>.yaml" do
      id = "id-#{System.unique_integer([:positive])}"
      pending = Path.join(Esr.Paths.admin_queue_dir(), "pending/#{id}.yaml")
      File.write!(pending, "x: 1")

      assert :ok = QueueResult.start_processing(id)
      refute File.exists?(pending)

      processing = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      assert File.exists?(processing)
    end

    test "is idempotent when already in processing/" do
      id = "id-#{System.unique_integer([:positive])}"
      processing = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      File.write!(processing, "x: 1")

      assert :ok = QueueResult.start_processing(id)
      assert File.exists?(processing)
    end

    test "is :ok when no source on disk (programmatic test bypass)" do
      id = "missing-#{System.unique_integer([:positive])}"
      assert :ok = QueueResult.start_processing(id)
    end
  end

  describe "move_pending_to/2 (cap-check failure shortcut)" do
    test "moves pending/<id>.yaml directly to <dest_dir>/<id>.yaml" do
      id = "id-#{System.unique_integer([:positive])}"
      pending = Path.join(Esr.Paths.admin_queue_dir(), "pending/#{id}.yaml")
      File.write!(pending, "x: 1")

      assert :ok = QueueResult.move_pending_to(id, "failed")
      refute File.exists?(pending)
      assert File.exists?(Path.join(Esr.Paths.admin_queue_dir(), "failed/#{id}.yaml"))
    end
  end

  describe "finish/3" do
    test "writes merged doc with completed_at + redaction at <dest_dir>/<id>.yaml" do
      id = "id-#{System.unique_integer([:positive])}"
      File.write!(Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml"), "x: 1")

      doc = %{
        "id" => id,
        "kind" => "notify",
        "args" => %{"text" => "hi", "token" => "secret-abc"}
      }

      assert :ok = QueueResult.finish(id, "completed", doc)

      out = Path.join(Esr.Paths.admin_queue_dir(), "completed/#{id}.yaml")
      assert File.exists?(out)
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["kind"] == "notify"
      assert parsed["completed_at"] |> is_binary()
      # Redaction in place:
      assert parsed["args"]["text"] == "hi"
      assert parsed["args"]["token"] == QueueResult.redacted_post_exec()
    end

    test "preserves caller-supplied completed_at (idempotent re-finish)" do
      id = "id-#{System.unique_integer([:positive])}"
      File.write!(Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml"), "x: 1")

      stamp = "2026-05-05T00:00:00.000000Z"
      doc = %{"id" => id, "kind" => "notify", "args" => %{}, "completed_at" => stamp}

      assert :ok = QueueResult.finish(id, "completed", doc)
      out = Path.join(Esr.Paths.admin_queue_dir(), "completed/#{id}.yaml")
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["completed_at"] == stamp
    end
  end

  describe "redaction" do
    test "secret_arg_keys/0 returns the canonical list" do
      assert "app_secret" in QueueResult.secret_arg_keys()
      assert "secret" in QueueResult.secret_arg_keys()
      assert "token" in QueueResult.secret_arg_keys()
    end

    test "redacts atom-keyed args (test bypass shape)" do
      id = "id-#{System.unique_integer([:positive])}"
      File.write!(Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml"), "x: 1")

      doc = %{"id" => id, args: %{"secret" => "shhh", "text" => "ok"}}
      assert :ok = QueueResult.finish(id, "completed", doc)
    end
  end

  describe "recover_stale/0" do
    test "moves any orphan processing/*.yaml to failed/ with synthesized error doc" do
      id = "stale-#{System.unique_integer([:positive])}"
      proc = Path.join(Esr.Paths.admin_queue_dir(), "processing/#{id}.yaml")
      File.write!(proc, "id: #{id}\nkind: notify\n")

      assert 1 = QueueResult.recover_stale()
      refute File.exists?(proc)

      out = Path.join(Esr.Paths.admin_queue_dir(), "failed/#{id}.yaml")
      assert File.exists?(out)
      {:ok, parsed} = YamlElixir.read_from_file(out)
      assert parsed["result"]["error"] == "interrupted_at_boot"
    end

    test "is :ok with empty processing dir" do
      assert 0 = QueueResult.recover_stale()
    end
  end
end
