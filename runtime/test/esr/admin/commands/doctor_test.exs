defmodule Esr.Admin.Commands.DoctorTest do
  @moduledoc """
  Tests for `Esr.Admin.Commands.Doctor` (PR-21κ).

  Doctor branches on (user_bound?, chat_bound?). We exercise the
  unbound-user branch (the most common bootstrap case) and verify the
  rendered guidance text mentions the correct esr.sh commands. The
  bound-but-no-workspace and healthy branches are covered indirectly
  via the next_steps_text/5 dispatch — we focus on verifying that
  Doctor returns text rather than reproducing the full bootstrap
  fixture stack.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Doctor

  test "unbound user → renders bind-feishu guidance" do
    open_id = "ou_unbound_#{System.unique_integer([:positive])}"

    assert {:ok, %{"text" => text}} =
             Doctor.execute(%{
               "args" => %{
                 "principal_id" => open_id,
                 "chat_id" => "oc_x",
                 "app_id" => "esr_dev_helper"
               }
             })

    assert text =~ "ESR 状态诊断"
    assert text =~ "未绑定"
    assert text =~ "user bind-feishu"
    assert text =~ open_id
    # env_hint maps esr_dev_helper → dev
    assert text =~ "--env=dev"
  end

  test "env_hint falls back to <prod|dev> for unknown app_id" do
    assert {:ok, %{"text" => text}} =
             Doctor.execute(%{
               "args" => %{
                 "principal_id" => "ou_y",
                 "chat_id" => "oc_y",
                 "app_id" => "unknown_app"
               }
             })

    assert text =~ "--env=<prod|dev>"
  end

  test "no args clause returns text" do
    assert {:ok, %{"text" => text}} = Doctor.execute(%{})
    assert is_binary(text)
    assert text != ""
  end
end
