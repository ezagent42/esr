defmodule Esr.UriStoreTest do
  @moduledoc """
  Unit tests for Esr.Uri facade (and the underlying Esr.Uri.Store).
  All URIs use the `esr://localhost/...` form required by Esr.Uri.parse/1.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §5, §11.1
  """
  use ExUnit.Case, async: false

  alias Esr.Entity.User.Registry.User

  setup do
    # Reset table to a known-empty state between tests.
    :ets.delete_all_objects(:esr_uri_store)
    :ok
  end

  describe "put_entity + lookup_raw round-trip" do
    test "stores entity row tagged :entity" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      data = %User{username: "alice"}
      assert :ok = Esr.Uri.put_entity(uri, :user, data)
      assert {:ok, {:entity, :user, ^data}} = Esr.Uri.Store.lookup_raw(uri)
    end
  end

  describe "alias/2" do
    test "happy path: alias points to canonical entity" do
      uuid = UUID.uuid4()
      canonical = "esr://localhost/users/" <> uuid
      :ok = Esr.Uri.put_entity(canonical, :user, %User{username: "alice"})

      assert :ok = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/alice")
      assert {:ok, ^canonical} = Esr.Uri.resolve("esr://localhost/users/by-name/alice")
    end

    test ":canonical_missing when target doesn't exist" do
      assert {:error, :canonical_missing} =
               Esr.Uri.alias("esr://localhost/users/nonexistent-uuid", "esr://localhost/users/by-name/x")
    end

    test ":target_is_alias rejects alias-of-alias (1-hop invariant)" do
      canonical = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(canonical, :user, %User{username: "alice"})
      :ok = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/alice")

      assert {:error, :target_is_alias} =
               Esr.Uri.alias("esr://localhost/users/by-name/alice", "esr://localhost/users/by-name/alice2")
    end

    test ":alias_exists when alias URI is already taken" do
      canonical1 = "esr://localhost/users/" <> UUID.uuid4()
      canonical2 = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(canonical1, :user, %User{username: "alice"})
      :ok = Esr.Uri.put_entity(canonical2, :user, %User{username: "bob"})

      :ok = Esr.Uri.alias(canonical1, "esr://localhost/users/by-name/alice")
      assert {:error, :alias_exists} =
               Esr.Uri.alias(canonical2, "esr://localhost/users/by-name/alice")
    end
  end

  describe "resolve/1" do
    test "canonical URI returns itself" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      assert {:ok, ^uri} = Esr.Uri.resolve(uri)
    end

    test "alias URI returns canonical" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      :ok = Esr.Uri.alias(uri, "esr://localhost/users/by-name/x")
      assert {:ok, ^uri} = Esr.Uri.resolve("esr://localhost/users/by-name/x")
    end

    test ":not_found for unknown URI (no plugin handler matches)" do
      assert :not_found = Esr.Uri.resolve("esr://localhost/users/nobody-here")
    end

    test ":not_found for non-binary input is gracefully :not_found" do
      assert :not_found = Esr.Uri.resolve(nil)
      assert :not_found = Esr.Uri.resolve(123)
    end
  end

  describe "get_entity/1" do
    test "via canonical URI" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      data = %User{username: "alice"}
      :ok = Esr.Uri.put_entity(uri, :user, data)
      assert {:ok, :user, ^data} = Esr.Uri.get_entity(uri)
    end

    test "via alias URI (alias→canonical chain)" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      data = %User{username: "alice"}
      :ok = Esr.Uri.put_entity(uri, :user, data)
      :ok = Esr.Uri.alias(uri, "esr://localhost/users/by-name/alice")
      assert {:ok, :user, ^data} = Esr.Uri.get_entity("esr://localhost/users/by-name/alice")
    end

    test ":not_found for unknown URI" do
      assert :not_found = Esr.Uri.get_entity("esr://localhost/users/nobody")
    end
  end

  describe "delete/1" do
    test "removes entity row; subsequent resolve is :not_found" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      assert :ok = Esr.Uri.delete(uri)
      assert :not_found = Esr.Uri.resolve(uri)
    end

    test "removing canonical leaves orphan aliases (deferred GC, spec §5.5)" do
      uri = "esr://localhost/users/" <> UUID.uuid4()
      :ok = Esr.Uri.put_entity(uri, :user, %User{username: "x"})
      :ok = Esr.Uri.alias(uri, "esr://localhost/users/by-name/x")

      :ok = Esr.Uri.delete(uri)

      # Alias row still exists in ETS but points to a now-missing canonical;
      # resolve via alias returns :not_found (resolve/1 returns alias's target,
      # but get_entity then can't find it).
      assert {:ok, _} = Esr.Uri.Store.lookup_raw("esr://localhost/users/by-name/x")
      # resolve returns the canonical (still in alias row) — but get_entity fails.
      # This is the documented deferred-GC behaviour.
    end
  end
end
