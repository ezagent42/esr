defmodule Esr.Test.UserFixture do
  @moduledoc """
  PR-1 (2026-05-12 URI identity migration) drop-in replacement for the
  deleted `Esr.Entity.User.Registry.load_snapshot_with_uuids/2` pattern
  used by tests as a fixture.

  Tests previously seeded users via:

      Esr.Entity.User.Registry.load_snapshot_with_uuids(
        %{"alice" => %Registry.User{username: "alice", feishu_ids: ["ou_a"]}},
        %{"alice" => "uuid-alice"}
      )

  After PR-1, users live in `:esr_uri_store`. This fixture writes the
  same canonical + by-name + per-feishu_id rows that FileLoader does at
  boot.
  """

  alias Esr.Entity.User.Struct, as: User

  @doc """
  Populate the URI store with a `%{username => %User{}}` snapshot. The
  `uuids` map (`%{username => uuid}`) supplies the canonical UUID for
  each user; usernames absent from `uuids` are silently skipped (same
  semantics as the old `load_snapshot_with_uuids/2`).

  Calls `Esr.Uri.Store.delete_all_by_kind(:user)` first so the snapshot
  fully replaces any previous user rows in the store — the boot-time
  invariant the old Registry's atomic snapshot reload provided.
  """
  @spec load_snapshot(%{String.t() => User.t()}, %{String.t() => String.t()}) :: :ok
  def load_snapshot(snapshot, uuids) when is_map(snapshot) and is_map(uuids) do
    ensure_uri_store!()
    Esr.Uri.Store.delete_all_by_kind(:user)

    Enum.each(snapshot, fn {username, %User{feishu_ids: ids} = user} ->
      case Map.get(uuids, username) do
        nil ->
          :ok

        uuid ->
          canonical = "esr://localhost/users/" <> uuid
          :ok = Esr.Uri.put_entity(canonical, :user, user)
          _ = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/" <> username)

          Enum.each(ids, fn ou_id ->
            _ = Esr.Uri.alias(canonical, "esr://localhost/users/feishu/" <> ou_id)
          end)
      end
    end)

    :ok
  end

  @doc """
  Replaces the old `Esr.Entity.User.Registry.load_snapshot/1` (no UUID
  map). Synthesizes a stable UUID per username — sufficient for tests
  that only care about by-name + feishu_id lookups.

  Passing an empty map clears the URI store of all :user rows
  (`load_snapshot(%{})` is the canonical test-isolation reset).
  """
  @spec load_snapshot(%{String.t() => User.t()}) :: :ok
  def load_snapshot(snapshot) when is_map(snapshot) do
    uuids =
      snapshot
      |> Map.keys()
      |> Enum.into(%{}, fn name -> {name, "test-uuid-" <> name} end)

    load_snapshot(snapshot, uuids)
  end

  @doc """
  Add or replace a single user. Convenience wrapper for tests that
  don't want to build the full snapshot map.
  """
  @spec put(String.t(), String.t(), [String.t()], String.t() | nil) :: :ok
  def put(username, uuid, feishu_ids \\ [], default_workspace_id \\ nil)
      when is_binary(username) and is_binary(uuid) and is_list(feishu_ids) do
    ensure_uri_store!()

    user = %User{
      username: username,
      feishu_ids: feishu_ids,
      default_workspace_id: default_workspace_id
    }

    canonical = "esr://localhost/users/" <> uuid
    :ok = Esr.Uri.put_entity(canonical, :user, user)
    _ = Esr.Uri.alias(canonical, "esr://localhost/users/by-name/" <> username)

    Enum.each(feishu_ids, fn ou_id ->
      _ = Esr.Uri.alias(canonical, "esr://localhost/users/feishu/" <> ou_id)
    end)

    :ok
  end

  @doc """
  Set default_workspace_id on an existing user entity row.
  """
  @spec set_default_workspace(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_default_workspace(username, ws_id)
      when is_binary(username) and is_binary(ws_id) do
    Esr.Uri.Compat.set_default_workspace_for_user_name(username, ws_id)
  end

  defp ensure_uri_store! do
    case Process.whereis(Esr.Uri.Store) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        raise "Esr.Uri.Store not running; tests using Esr.Test.UserFixture must " <>
                "either start_supervised!({Esr.Uri.Store, []}) in setup, or run " <>
                "with the application supervisor up"
    end
  end
end
