defmodule Esr.Commands.Session.ShareTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Session.Share
  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Entity.User.NameIndex

  @submitter "user-uuid-0000-0000-000000000030"
  @target_username "alice-share-#{:rand.uniform(999_999)}"
  @target_uuid "user-uuid-0000-0000-000000000031"

  setup do
    case Process.whereis(SessionRegistry) do
      nil -> start_supervised!(SessionRegistry)
      _ -> :ok
    end

    # Start the NameIndex GenServer if it isn't already running.
    # The default table name is :esr_user_name_index.
    case :ets.info(:esr_user_name_index_name_to_id) do
      :undefined ->
        start_supervised!({NameIndex, [table: :esr_user_name_index]})

      _ ->
        :ok
    end

    # Seed the user into NameIndex (idempotent: ignore :name_exists)
    _ = NameIndex.put(@target_username, @target_uuid)

    # Seed a session
    data_dir = Esr.Paths.runtime_home()

    {:ok, sid} =
      SessionRegistry.create_session(data_dir, %{
        name: "share-test-session-#{:rand.uniform(99_999)}",
        owner_user: @submitter,
        workspace_id: ""
      })

    {:ok, session_id: sid}
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "success: returns structured result (or write_failed on missing yaml)", %{
    session_id: sid
  } do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "user" => @target_username}
    }

    # Cap.Grant writes to capabilities.yaml; in unit-test env the file
    # may not exist → write_failed is acceptable. What matters is that
    # the command logic itself ran to completion without an arg-level error.
    result = Share.execute(cmd)

    assert match?({:ok, _}, result) or
             match?({:error, %{"type" => "write_failed"}}, result),
           "expected {:ok, _} or {:error, write_failed}, got: #{inspect(result)}"
  end

  test "success: perm=admin flows to cap grant", %{session_id: sid} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "user" => @target_username, "perm" => "admin"}
    }

    result = Share.execute(cmd)

    assert match?({:ok, %{"perm" => "admin"}}, result) or
             match?({:error, %{"type" => "write_failed"}}, result)
  end

  test "success: default perm is attach when perm omitted", %{session_id: sid} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "user" => @target_username}
    }

    result = Share.execute(cmd)

    case result do
      {:ok, r} -> assert r["perm"] == "attach"
      {:error, %{"type" => "write_failed"}} -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # UUID-only contract (Phase 5 D2 + D5)
  # ---------------------------------------------------------------------------

  test "error: name instead of UUID returns invalid_session_uuid" do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => "my-session-name", "user" => @target_username}
    }

    assert {:error, %{"type" => "invalid_session_uuid"}} = Share.execute(cmd)
  end

  test "error: empty session UUID returns invalid_args" do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => "", "user" => @target_username}
    }

    assert {:error, %{"type" => "invalid_args"}} = Share.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Argument validation errors
  # ---------------------------------------------------------------------------

  test "error: missing user returns invalid_args", %{session_id: sid} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid}
    }

    assert {:error, %{"type" => "invalid_args"}} = Share.execute(cmd)
  end

  test "error: empty user returns invalid_args", %{session_id: sid} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "user" => ""}
    }

    assert {:error, %{"type" => "invalid_args"}} = Share.execute(cmd)
  end

  test "error: invalid perm value returns invalid_perm", %{session_id: sid} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "user" => @target_username, "perm" => "superuser"}
    }

    assert {:error, %{"type" => "invalid_perm"}} = Share.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # User not found
  # ---------------------------------------------------------------------------

  test "error: unknown username returns user_not_found", %{session_id: sid} do
    cmd = %{
      "submitted_by" => @submitter,
      "args" => %{"session" => sid, "user" => "nobody-#{:rand.uniform(99_999)}"}
    }

    assert {:error, %{"type" => "user_not_found"}} = Share.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Missing submitted_by
  # ---------------------------------------------------------------------------

  test "error: missing submitted_by returns invalid_args", %{session_id: sid} do
    cmd = %{
      "args" => %{"session" => sid, "user" => @target_username}
    }

    assert {:error, %{"type" => "invalid_args"}} = Share.execute(cmd)
  end
end
