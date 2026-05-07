defmodule EsrWeb.SlashSchemaControllerTest do
  @moduledoc """
  Phase 6.5 — colon-namespace smoke test for GET /admin/slash_schema.json.

  The controller serialises route.slash fields directly from
  Registry.list_slashes/0. After the Phase 6 yaml rewrite all slash names
  are in colon form; old-form names must be absent.
  """

  use EsrWeb.ConnCase, async: false

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  setup do
    # Ensure the priv default yaml is loaded so colon-form slashes are present.
    priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
    if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
    :ok
  end

  describe "GET /admin/slash_schema.json — colon-namespace (Phase 6.5)" do
    test "response is 200 with JSON body", %{conn: conn} do
      conn = get(conn, "/admin/slash_schema.json")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "response contains colon-form slash names", %{conn: conn} do
      conn = get(conn, "/admin/slash_schema.json")
      body = Jason.decode!(conn.resp_body)
      slashes = body["slashes"] || []

      slash_names = Enum.map(slashes, &Map.get(&1, "slash"))

      assert Enum.any?(slash_names, &(is_binary(&1) and String.contains?(&1, ":"))),
             "expected at least one colon-form slash name in response, got: #{inspect(slash_names)}"

      assert Enum.any?(slash_names, &(is_binary(&1) and String.starts_with?(&1, "/workspace:"))),
             "expected /workspace:* entries in response"
    end

    test "response does NOT contain old-form slash names", %{conn: conn} do
      conn = get(conn, "/admin/slash_schema.json")
      body = Jason.decode!(conn.resp_body)
      slashes = body["slashes"] || []
      slash_names = Enum.map(slashes, &Map.get(&1, "slash"))

      refute Enum.any?(slash_names, &(&1 == "/new-session")),
             "old-form /new-session should not appear in schema endpoint"

      refute Enum.any?(slash_names, &(&1 == "/workspace sessions")),
             "/workspace sessions should be absent (Rule 6)"

      refute Enum.any?(slash_names, &(&1 == "/whoami")),
             "old-form /whoami should not appear; use /user:whoami"
    end

    test "/workspace:sessions is absent from response (Rule 6)", %{conn: conn} do
      conn = get(conn, "/admin/slash_schema.json")
      body = Jason.decode!(conn.resp_body)
      slashes = body["slashes"] || []
      slash_names = Enum.map(slashes, &Map.get(&1, "slash"))

      refute Enum.any?(slash_names, &(&1 == "/workspace:sessions")),
             "/workspace:sessions should be absent (workspace must not depend on session)"
    end
  end
end
