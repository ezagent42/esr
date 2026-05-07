defmodule Esr.Resource.Capability.UuidTranslatorTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Capability.UuidTranslator

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  describe "existing workspace name↔uuid — still works" do
    test "name_to_uuid passes through non-session non-workspace cap" do
      assert {:ok, "user.manage"} = UuidTranslator.name_to_uuid("user.manage")
    end

    test "uuid_to_name passes through non-scoped cap" do
      assert "runtime.deadletter" = UuidTranslator.uuid_to_name("runtime.deadletter")
    end
  end

  describe "validate_session_cap_input/1" do
    test "session cap with UUID is accepted" do
      cap = "session:#{@session_uuid}/attach"
      assert :ok = UuidTranslator.validate_session_cap_input(cap)
    end

    test "session cap with name (not UUID) is rejected" do
      assert {:error, {:session_name_in_cap, _msg}} =
               UuidTranslator.validate_session_cap_input("session:esr-dev/attach")
    end

    test "non-session cap passes through regardless of value" do
      assert :ok = UuidTranslator.validate_session_cap_input("workspace:my-ws/read")
      assert :ok = UuidTranslator.validate_session_cap_input("user.manage")
    end

    test "session cap with partial UUID rejected" do
      assert {:error, {:session_name_in_cap, _}} =
               UuidTranslator.validate_session_cap_input("session:not-a-uuid/end")
    end
  end

  describe "session_uuid_to_name/2 (output-only)" do
    test "unknown UUID returns UNKNOWN sentinel" do
      # Session.Registry not running in this unit test; :not_found expected.
      result = UuidTranslator.session_uuid_to_name(@session_uuid, %{})
      assert {:error, :not_found} = result
    end

    test "name_to_uuid does NOT translate session: names (no session_name_to_uuid)" do
      # Session name input should be rejected by validate_session_cap_input,
      # NOT silently translated. name_to_uuid leaves session: untouched.
      assert {:ok, "session:esr-dev/attach"} =
               UuidTranslator.name_to_uuid("session:esr-dev/attach")
    end
  end
end
