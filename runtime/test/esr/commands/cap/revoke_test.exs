defmodule Esr.Commands.Cap.RevokeTest do
  use ExUnit.Case, async: true
  alias Esr.Commands.Cap.Revoke

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @user_id "user_linyilun"

  describe "session cap UUID-only enforcement" do
    test "revoke session:<name>/attach is rejected with session_cap_requires_uuid" do
      cap = "session:esr-dev/attach"
      assert {:error, %{"type" => "session_cap_requires_uuid"}} =
               Revoke.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
    end

    test "revoke session:<uuid>/attach passes UUID gate (may return no_matching_capability)" do
      cap = "session:#{@session_uuid}/attach"
      result = Revoke.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
    end
  end
end
