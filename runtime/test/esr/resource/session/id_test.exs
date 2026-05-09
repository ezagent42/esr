defmodule Esr.Resource.Session.IdTest do
  use ExUnit.Case, async: true

  alias Esr.Resource.Session.Id

  @uuid_v4_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "new/0 returns a UUID v4 string" do
    sid = Id.new()
    assert is_binary(sid)
    assert String.length(sid) == 36
    assert Regex.match?(@uuid_v4_re, sid),
           "expected UUID v4 format, got: #{inspect(sid)}"
  end

  test "new/0 returns distinct values across calls" do
    a = Id.new()
    b = Id.new()
    refute a == b
  end

  test "new/0 contract guards Phase 5 D2: session caps assume UUID v4" do
    # Cap routing parses session_id as UUID. ULID / base32 / any non-UUID
    # form would silently break the cap chain. This test pins the format
    # contract so a future strategy switch (e.g. UUID v7) is a deliberate
    # decision, not a drive-by edit.
    for _ <- 1..50 do
      assert Regex.match?(@uuid_v4_re, Id.new())
    end
  end
end
