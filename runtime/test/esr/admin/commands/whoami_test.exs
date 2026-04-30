defmodule Esr.Admin.Commands.WhoamiTest do
  @moduledoc """
  Tests for `Esr.Admin.Commands.Whoami` (PR-21κ).

  Whoami reads from `Users.Registry` + `Workspaces.Registry`. The
  Application starts both as singletons, so we just feed args and
  assert the rendered text reflects the lookup outcomes.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Whoami

  test "renders unbound state when open_id is unknown" do
    assert {:ok, %{"text" => text}} =
             Whoami.execute(%{
               "args" => %{
                 "principal_id" => "ou_does_not_exist_#{System.unique_integer([:positive])}",
                 "chat_id" => "oc_test",
                 "app_id" => "test_app"
               }
             })

    assert text =~ "你的 ESR 身份"
    assert text =~ "未绑定"
    assert text =~ "open_id:"
    assert text =~ "chat_id: oc_test"
    assert text =~ "app_id (instance): test_app"
  end

  test "shows workspace = (无) when chat is not bound" do
    assert {:ok, %{"text" => text}} =
             Whoami.execute(%{
               "args" => %{
                 "principal_id" => "ou_x",
                 "chat_id" => "oc_unbound_#{System.unique_integer([:positive])}",
                 "app_id" => "test_app"
               }
             })

    assert text =~ "workspace: (无)"
  end

  test "missing args fall back to (unknown)" do
    assert {:ok, %{"text" => text}} = Whoami.execute(%{"args" => %{}})
    assert text =~ "(unknown)"
  end

  test "no args clause returns non-empty text" do
    assert {:ok, %{"text" => text}} = Whoami.execute(%{})
    assert is_binary(text)
    assert text != ""
  end
end
