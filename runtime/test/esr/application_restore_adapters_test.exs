defmodule Esr.ApplicationRestoreAdaptersTest do
  @moduledoc """
  Per yaml-layout-v2 (spec § 4.7) — `restore_adapters_from_disk/2`
  reads the per-thing-directory layout via `Esr.Adapters.list/1`. The
  legacy `plugins.yaml :config.feishu.app_secret` fallback is removed:
  a feishu row missing `app_secret` fails loud (Logger.error) and is
  skipped (no spawn). The cleanup-A standalone PR is subsumed here.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    prev = System.get_env("ESRD_HOME")

    on_exit(fn ->
      if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
    end)

    :ok
  end

  defp with_tmp_home(suffix, fun) do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "esr-restore-#{suffix}-#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    System.put_env("ESRD_HOME", tmp)

    try do
      fun.(tmp)
    after
      File.rm_rf!(tmp)
    end
  end

  test "per-instance directories restoration calls spawn_fn per active instance" do
    with_tmp_home("ok", fn tmp ->
      instance_name = "feishu_test_#{System.unique_integer([:positive])}"

      :ok =
        Esr.Adapters.add(
          instance_name,
          "feishu",
          %{"app_id" => "cli_x", "app_secret" => "secret"}
        )

      parent = self()

      :ok =
        Esr.Application.restore_adapters_from_disk(tmp,
          spawn_fn: fn name, type, config ->
            send(parent, {:spawned, name, type, config})
            :ok
          end
        )

      assert_received {:spawned, ^instance_name, "feishu",
                       %{"app_id" => "cli_x", "app_secret" => "secret"}}
    end)
  end

  test "no adapters/ tree → no-op (empty list)" do
    with_tmp_home("empty", fn tmp ->
      parent = self()

      assert :ok =
               Esr.Application.restore_adapters_from_disk(tmp,
                 spawn_fn: fn _, _, _ ->
                   send(parent, :should_not_fire)
                   :ok
                 end
               )

      refute_received :should_not_fire
    end)
  end

  test "handles multiple active instances" do
    with_tmp_home("multi", fn tmp ->
      :ok = Esr.Adapters.add("a_inst", "feishu", %{"app_id" => "a", "app_secret" => "1"})
      :ok = Esr.Adapters.add("b_inst", "feishu", %{"app_id" => "b", "app_secret" => "2"})

      parent = self()

      :ok =
        Esr.Application.restore_adapters_from_disk(tmp,
          spawn_fn: fn name, _type, _cfg ->
            send(parent, {:got, name})
            :ok
          end
        )

      assert_received {:got, "a_inst"}
      assert_received {:got, "b_inst"}
    end)
  end

  test "disabled instances under adapters/_disabled/ are NOT spawned" do
    with_tmp_home("disabled", fn tmp ->
      :ok = Esr.Adapters.add("active_one", "feishu", %{"app_id" => "a", "app_secret" => "s"})
      :ok = Esr.Adapters.add("paused_one", "feishu", %{"app_id" => "b", "app_secret" => "s"})
      :ok = Esr.Adapters.disable("paused_one")

      parent = self()

      :ok =
        Esr.Application.restore_adapters_from_disk(tmp,
          spawn_fn: fn name, _, _ ->
            send(parent, {:spawned, name})
            :ok
          end
        )

      assert_received {:spawned, "active_one"}
      refute_received {:spawned, "paused_one"}
    end)
  end

  describe "cleanup A subsumed (no plugins.yaml app_secret fallback)" do
    test "feishu row missing app_secret fails loud, does NOT spawn" do
      with_tmp_home("nosecret", fn tmp ->
        :ok = Esr.Adapters.add("feishu_lonely", "feishu", %{"app_id" => "cli_lonely"})

        parent = self()

        log =
          capture_log(fn ->
            :ok =
              Esr.Application.restore_adapters_from_disk(tmp,
                spawn_fn: fn name, _type, _cfg ->
                  send(parent, {:should_not_fire, name})
                  :ok
                end
              )
          end)

        # Skip-spawn: the feishu row with no secret never reaches spawn_fn.
        refute_received {:should_not_fire, "feishu_lonely"}

        # Fail-loud: error log carries the actionable cleanup hint.
        assert log =~ ~r/feishu adapter 'feishu_lonely' missing app_secret in adapters\/feishu_lonely\/config\.yaml/
        assert log =~ "register_adapter"
      end)
    end

    test "non-feishu rows missing app_secret are unaffected (no spawn-skip)" do
      with_tmp_home("nonfeishu", fn tmp ->
        :ok = Esr.Adapters.add("ccmcp_inst", "cc_mcp", %{})

        parent = self()

        :ok =
          Esr.Application.restore_adapters_from_disk(tmp,
            spawn_fn: fn name, type, _ ->
              send(parent, {:spawned, name, type})
              :ok
            end
          )

        assert_received {:spawned, "ccmcp_inst", "cc_mcp"}
      end)
    end

    test "other valid feishu rows still spawn even when one row is skipped" do
      with_tmp_home("mixed", fn tmp ->
        :ok = Esr.Adapters.add("good_row", "feishu", %{"app_id" => "g", "app_secret" => "yes"})
        :ok = Esr.Adapters.add("bad_row", "feishu", %{"app_id" => "b"})

        parent = self()

        capture_log(fn ->
          :ok =
            Esr.Application.restore_adapters_from_disk(tmp,
              spawn_fn: fn name, _, _ ->
                send(parent, {:spawned, name})
                :ok
              end
            )
        end)

        assert_received {:spawned, "good_row"}
        refute_received {:spawned, "bad_row"}
      end)
    end
  end
end
