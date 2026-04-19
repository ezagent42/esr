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
  end

  describe "build/3" do
    test "assembles local URI without port" do
      assert Esr.Uri.build(:actor, "cc:sess-A", "localhost") ==
               "esr://localhost/actor/cc:sess-A"
    end

    test "assembles URI for every valid type" do
      for type <- [:actor, :adapter, :handler, :command, :interface] do
        uri = Esr.Uri.build(type, "x", "localhost")
        assert uri == "esr://localhost/#{type}/x"
      end
    end
  end
end
