defmodule Esr.Commands.DoctorTest do
  @moduledoc """
  Tests for `Esr.Commands.Doctor` (PR-21κ).

  Doctor branches on (user_bound?, chat_bound?). We exercise the
  unbound-user branch (the most common bootstrap case) and verify the
  rendered guidance text mentions the correct esr escript commands. The
  bound-but-no-workspace and healthy branches are covered indirectly
  via the next_steps_text/5 dispatch — we focus on verifying that
  Doctor returns text rather than reproducing the full bootstrap
  fixture stack.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Doctor

  test "unbound user → renders bind-feishu guidance (post-2026-05-09 grammar)" do
    open_id = "ou_unbound_#{System.unique_integer([:positive])}"

    assert {:ok, %{"text" => text}} =
             Doctor.execute(%{
               "args" => %{
                 "caller_principal_id" => open_id,
                 "chat_id" => "oc_x",
                 "app_id" => "esr_dev_helper"
               }
             })

    assert text =~ "ESR 状态诊断"
    assert text =~ "未绑定"
    # New grammar: kind-form CLI command (was old `esr --env=dev feishu bind ...`)
    assert text =~ "esr exec user_add"
    assert text =~ "esr exec feishu_bind"
    assert text =~ open_id
    # Old --env= flag is gone (removed with grammar refresh)
    refute text =~ "--env=dev"
  end

  test "unbound user with chat-only branch produces guidance" do
    assert {:ok, %{"text" => text}} =
             Doctor.execute(%{
               "args" => %{
                 "caller_principal_id" => "ou_y",
                 "chat_id" => "oc_y",
                 "app_id" => "unknown_app"
               }
             })

    # User unbound takes precedence; the guidance points at user_add.
    assert text =~ "未绑定"
    assert text =~ "esr exec user_add"
  end

  test "no args clause returns text" do
    assert {:ok, %{"text" => text}} = Doctor.execute(%{})
    assert is_binary(text)
    assert text != ""
  end
end
