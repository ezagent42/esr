defmodule Esr.UriTest do
  @moduledoc """
  PRD 01 F17 — esr:// URI parser and builder (spec §7.5). Host is
  required; empty host is a syntax error.
  """

  use ExUnit.Case, async: true

  describe "parse/1" do
    test "valid local URI" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/actor/cc:sess-A")
      assert uri.host == "localhost"
      assert uri.port == nil
      assert uri.type == :actor
      assert uri.id == "cc:sess-A"
    end

    test "valid remote URI with port" do
      {:ok, uri} = Esr.Uri.parse("esr://laptop-2.local:4000/adapter/zellij-5")
      assert uri.host == "laptop-2.local"
      assert uri.port == 4000
      assert uri.type == :adapter
      assert uri.id == "zellij-5"
    end

    test "valid URI with org" do
      {:ok, uri} = Esr.Uri.parse("esr://allens-lab@host.example/interface/customer_inquiry")
      assert uri.org == "allens-lab"
      assert uri.host == "host.example"
      assert uri.type == :interface
    end

    test "empty host rejected" do
      assert {:error, :empty_host} = Esr.Uri.parse("esr:///actor/cc:sess-A")
    end

    test "unknown type rejected" do
      assert {:error, :unknown_type} = Esr.Uri.parse("esr://localhost/unknown/x")
    end

    test "missing scheme rejected" do
      assert {:error, :bad_scheme} = Esr.Uri.parse("http://localhost/actor/x")
    end

    test "malformed path rejected" do
      assert {:error, :bad_path} = Esr.Uri.parse("esr://localhost/actor")
    end

    test "parses query params" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/command/feishu-to-cc?ver=2")
      assert uri.params == %{"ver" => "2"}
    end

    test "legacy types fill segments with [type, id]" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/actor/cc:sess-A")
      assert uri.segments == ["actor", "cc:sess-A"]
    end

    test "path-style adapter URI" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/adapters/feishu/app_dev")
      assert uri.host == "localhost"
      assert uri.type == :adapters
      assert uri.id == "app_dev"
      assert uri.segments == ["adapters", "feishu", "app_dev"]
    end

    test "path-style chat URI under workspace" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/workspaces/ws_dev/chats/oc_xxx")
      assert uri.type == :workspaces
      assert uri.id == "oc_xxx"
      assert uri.segments == ["workspaces", "ws_dev", "chats", "oc_xxx"]
    end

    test "path-style user URI" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/users/ou_abc")
      assert uri.type == :users
      assert uri.id == "ou_abc"
      assert uri.segments == ["users", "ou_abc"]
    end

    test "path-style session URI" do
      {:ok, uri} = Esr.Uri.parse("esr://localhost/sessions/sess_42")
      assert uri.type == :sessions
      assert uri.id == "sess_42"
      assert uri.segments == ["sessions", "sess_42"]
    end

    test "legacy 2-segment with single id rejects extra slashes for legacy types" do
      # Legacy types stay strict: actor/<id> with id containing no slashes.
      assert {:error, :unknown_type} = Esr.Uri.parse("esr://localhost/notatype/a/b")
    end

    test "path-style with only collection segment rejected" do
      assert {:error, :bad_path} = Esr.Uri.parse("esr://localhost/adapters")
    end
  end

  describe "build/3" do
    test "assembles local URI without port" do
      assert Esr.Uri.build(:actor, "cc:sess-A", "localhost") ==
               "esr://localhost/actor/cc:sess-A"
    end

    test "assembles URI for every legacy type" do
      for type <- [:actor, :adapter, :handler, :command, :interface] do
        uri = Esr.Uri.build(type, "x", "localhost")
        assert uri == "esr://localhost/#{type}/x"
      end
    end
  end

  describe "build_path/2" do
    test "assembles path-style adapter URI" do
      assert Esr.Uri.build_path(["adapters", "feishu", "app_dev"], "localhost") ==
               "esr://localhost/adapters/feishu/app_dev"
    end

    test "assembles path-style chat URI under workspace" do
      assert Esr.Uri.build_path(
               ["workspaces", "ws_dev", "chats", "oc_xxx"],
               "localhost"
             ) == "esr://localhost/workspaces/ws_dev/chats/oc_xxx"
    end

    test "rejects legacy first segment" do
      assert_raise ArgumentError, fn ->
        Esr.Uri.build_path(["actor", "x"], "localhost")
      end
    end

    test "round-trip parse(build_path)" do
      uri_str = Esr.Uri.build_path(["users", "ou_abc"], "localhost")
      {:ok, uri} = Esr.Uri.parse(uri_str)
      assert uri.segments == ["users", "ou_abc"]
    end

    test "build_path with :org emits org@host (PR-21b)" do
      uri = Esr.Uri.build_path(["sessions", "linyilun", "ws", "foo"], "localhost", org: "default")
      assert uri == "esr://default@localhost/sessions/linyilun/ws/foo"
    end

    test "build_path round-trips through parser with :org" do
      uri_str =
        Esr.Uri.build_path(
          ["sessions", "linyilun", "esr-dev", "feature"],
          "localhost",
          org: "default"
        )

      {:ok, uri} = Esr.Uri.parse(uri_str)
      assert uri.org == "default"
      assert uri.host == "localhost"
      assert uri.segments == ["sessions", "linyilun", "esr-dev", "feature"]
    end

    test "build_path with nil org behaves identically to no opts" do
      assert Esr.Uri.build_path(["users", "x"], "localhost", org: nil) ==
               Esr.Uri.build_path(["users", "x"], "localhost")
    end

    test "build with :org emits org@host (PR-21b symmetry)" do
      assert Esr.Uri.build(:actor, "cc:sess", "localhost", org: "default") ==
               "esr://default@localhost/actor/cc:sess"
    end
  end

  describe "type set helpers" do
    test "legacy_types/0 returns the singular legacy type set" do
      assert :actor in Esr.Uri.legacy_types()
      assert :adapter in Esr.Uri.legacy_types()
      refute :adapters in Esr.Uri.legacy_types()
    end

    test "path_style_types/0 returns the new RESTful type set" do
      assert :adapters in Esr.Uri.path_style_types()
      assert :workspaces in Esr.Uri.path_style_types()
      assert :chats in Esr.Uri.path_style_types()
      assert :users in Esr.Uri.path_style_types()
      assert :sessions in Esr.Uri.path_style_types()
      refute :actor in Esr.Uri.path_style_types()
    end
  end
end
