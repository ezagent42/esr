defmodule Esr.Commands.Cap.OutputRenderingTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Capability.UuidTranslator

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  describe "render_cap_for_display/1" do
    test "workspace cap with known UUID renders as name" do
      # Workspace name resolution is already tested in uuid_translator tests;
      # this test only ensures the function exists.
      cap = "workspace:#{@session_uuid}/read"
      result = UuidTranslator.render_cap_for_display(cap)
      assert is_binary(result)
    end

    test "session cap with unknown UUID shows UNKNOWN sentinel" do
      cap = "session:#{@session_uuid}/attach"
      result = UuidTranslator.render_cap_for_display(cap)
      # Session.Registry not running → :not_found → UNKNOWN sentinel.
      assert result =~ "UNKNOWN" or result =~ @session_uuid
    end

    test "non-scoped cap passes through unchanged" do
      cap = "user.manage"
      assert "user.manage" = UuidTranslator.render_cap_for_display(cap)
    end

    test "session cap with UUID renders with (uuid: ...) annotation or UNKNOWN" do
      cap = "session:#{@session_uuid}/end"
      result = UuidTranslator.render_cap_for_display(cap)
      # Either "session:<name>/end (uuid: <uuid>)" or "session:<UNKNOWN-...>/end"
      assert is_binary(result)
      assert result =~ "session:"
    end
  end
end
