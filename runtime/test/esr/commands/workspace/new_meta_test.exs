defmodule Esr.Commands.Workspace.NewMetaTest do
  @moduledoc """
  Locks in the contract of Workspace.New so the Phase 2 DSL conversion
  (and Phase 3 bulk conversions of similar modules) cannot silently
  rename an error type or change required-arg validation.
  """

  use ExUnit.Case, async: true

  alias Esr.Commands.Workspace.New

  test "no args returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"} = body} = New.execute(%{})
    assert body["message"] =~ "name"
  end

  test "empty args.name returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} = New.execute(%{"args" => %{}})
  end

  test "name with disallowed chars returns invalid_name" do
    assert {:error, %{"type" => "invalid_name"} = body} =
             New.execute(%{"args" => %{"name" => "has space", "username" => "linyilun"}})

    assert body["message"] =~ "ASCII alnum"
  end

  test "command_meta/0 declares all error types the module currently emits" do
    spec = New.command_meta()
    declared = Enum.map(spec.errors, & &1.code) |> MapSet.new()

    expected =
      MapSet.new([
        :invalid_args,
        :invalid_name,
        :unknown_owner,
        :folder_not_dir,
        :folder_not_git_repo,
        :transient_repo_bound_forbidden,
        :name_exists,
        :registry_put_failed
      ])

    missing = MapSet.difference(expected, declared)
    extra = MapSet.difference(declared, expected)

    assert MapSet.size(missing) == 0,
           "command_meta missing error codes: #{inspect(MapSet.to_list(missing))}"

    assert MapSet.size(extra) == 0,
           "command_meta declares unused error codes: #{inspect(MapSet.to_list(extra))}"
  end

  test "command_meta/0 reproduces the slash-routes.default.yaml row for /workspace:new" do
    spec = New.command_meta()
    assert spec.kind == :workspace_new
    assert spec.slash == "/workspace:new"
    assert spec.category == "Workspace"
    assert spec.permission == "workspace.create"
    assert spec.requires_user_binding
    refute spec.requires_workspace_binding

    arg_names = Enum.map(spec.args, & &1.name)
    assert arg_names == [:name, :folder, :transient, :owner]

    assert Enum.find(spec.args, &(&1.name == :name)).required
    refute Enum.find(spec.args, &(&1.name == :folder)).required
  end
end
