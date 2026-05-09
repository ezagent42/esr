defmodule Esr.Commands.MetaTest do
  use ExUnit.Case, async: true

  alias Esr.Commands.Meta.{Spec, Arg, ErrorDecl}

  test "Spec struct holds kind/slash/category/description/permission/binding flags/args/errors" do
    spec = %Spec{
      kind: :workspace_new,
      slash: "/workspace:new",
      category: "Workspace",
      description: "create a workspace",
      permission: "workspace.create",
      requires_user_binding: true,
      requires_workspace_binding: false,
      args: [],
      errors: []
    }

    assert spec.kind == :workspace_new
    assert spec.slash == "/workspace:new"
  end

  test "Arg holds name/required/default/doc" do
    arg = %Arg{name: :name, required: true, default: nil, doc: "workspace name"}
    assert arg.name == :name
    assert arg.required
  end

  test "ErrorDecl holds code/message" do
    err = %ErrorDecl{code: :invalid_args, message: "args.name missing"}
    assert err.code == :invalid_args
  end

  defmodule Fixture do
    use Esr.Commands.Meta

    command :test_cmd do
      slash "/test:cmd"
      category "Tests"
      description "fixture command"
      permission "test.run"
      requires_user_binding true
      requires_workspace_binding false

      arg :name, required: true, doc: "the name"
      arg :force, required: false, default: "false"

      error :invalid_args, "missing args.name"
      error :unknown_target
    end

    def execute(_), do: {:ok, %{}}
  end

  test "DSL produces a populated Spec via command_meta/0" do
    spec = Fixture.command_meta()
    assert spec.kind == :test_cmd
    assert spec.slash == "/test:cmd"
    assert spec.category == "Tests"
    assert spec.description == "fixture command"
    assert spec.permission == "test.run"
    assert spec.requires_user_binding
    refute spec.requires_workspace_binding
    assert length(spec.args) == 2

    [first | _] = spec.args
    assert first.name == :name
    assert first.required

    assert length(spec.errors) == 2
    assert Enum.find(spec.errors, &(&1.code == :invalid_args)).message == "missing args.name"
    assert Enum.find(spec.errors, &(&1.code == :unknown_target)).message == nil
  end

  test "DSL rejects duplicate error codes at compile time" do
    assert_raise CompileError, ~r/duplicate error code :foo/, fn ->
      Code.eval_string("""
      defmodule Esr.Commands.MetaTest.DupErrorFixture do
        use Esr.Commands.Meta
        command :dup_err do
          slash "/dup"
          category "X"
          description "x"
          error :foo, "first"
          error :foo, "second"
        end
        def execute(_), do: {:ok, %{}}
      end
      """)
    end
  end

  test "DSL accepts slash :none for internal kinds" do
    defmodule InternalFixture do
      use Esr.Commands.Meta

      command :internal_only do
        slash :none
        category "其他"
        description "internal"
      end

      def execute(_), do: {:ok, %{}}
    end

    assert InternalFixture.command_meta().slash == :none
  end

  test "Esr.Commands.Meta declares execute/1 + command_meta/0 as @callback" do
    callbacks = Esr.Commands.Meta.behaviour_info(:callbacks)
    assert {:execute, 1} in callbacks
    assert {:command_meta, 0} in callbacks
  end
end
