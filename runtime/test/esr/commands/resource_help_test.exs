defmodule Esr.Commands.ResourceHelpTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.ResourceHelp

  setup do
    # Boot the slash-routes registry so list_slashes/0 has data.
    # Skip if already running (tests in the same suite may have started it).
    case start_supervised({Esr.Resource.SlashRoute.Registry, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "execute with resource=workspace returns text listing workspace:* methods" do
    {:ok, %{"text" => text}} =
      ResourceHelp.execute(%{"args" => %{"resource" => "workspace"}})

    assert text =~ "/workspace:new"
    assert text =~ "/workspace:list"
  end

  test "execute with unknown resource returns a friendly error listing valid resources" do
    {:ok, %{"text" => text}} =
      ResourceHelp.execute(%{"args" => %{"resource" => "doesnotexist"}})

    assert text =~ "doesnotexist"
    assert text =~ "未知 resource"
  end

  test "execute with no resource arg lists top-level resources" do
    {:ok, %{"text" => text}} = ResourceHelp.execute(%{"args" => %{}})
    assert text =~ "workspace"
    assert text =~ "session"
  end

  test "execute with no args at all lists top-level resources" do
    {:ok, %{"text" => text}} = ResourceHelp.execute(%{})
    assert text =~ "top-level resources"
  end
end
