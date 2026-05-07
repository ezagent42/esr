defmodule Esr.Commands.Cap.GrantTest do
  use ExUnit.Case, async: true
  alias Esr.Commands.Cap.Grant

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @user_id "user_linyilun"

  describe "session cap UUID-only enforcement" do
    test "grant session:<uuid>/attach succeeds (passes validation gate)" do
      cap = "session:#{@session_uuid}/attach"
      # Result is {:ok, _} or {:error, write_failed} depending on disk state;
      # the important assertion is: no session_cap_requires_uuid error.
      result = Grant.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      assert match?({:ok, _}, result) or match?({:error, %{"type" => "write_failed"}}, result)
      refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
    end

    test "grant session:<name>/attach is rejected with session_cap_requires_uuid" do
      cap = "session:esr-dev/attach"
      assert {:error, %{"type" => "session_cap_requires_uuid", "message" => msg}} =
               Grant.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      assert msg =~ "esr-dev"
    end

    test "grant workspace:<name>/read passes through unchanged (not affected by session guard)" do
      cap = "workspace:my-ws/read"
      result = Grant.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      # Either succeeds or write_failed or unknown_workspace — never session_cap_requires_uuid.
      refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
    end
  end
end
