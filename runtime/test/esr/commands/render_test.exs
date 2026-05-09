defmodule Esr.Commands.RenderTest do
  use ExUnit.Case, async: true

  alias Esr.Commands.Meta.{Spec, Arg, ErrorDecl}
  alias Esr.Commands.Render

  defp sample_spec do
    %Spec{
      kind: :workspace_new,
      slash: "/workspace:new",
      category: "Workspace",
      description: "create a new workspace",
      permission: "workspace.create",
      requires_user_binding: true,
      requires_workspace_binding: false,
      args: [
        %Arg{name: :name, required: true, doc: "workspace name"},
        %Arg{name: :folder, required: false, doc: "absolute git repo path"}
      ],
      errors: [
        %ErrorDecl{code: :invalid_args, message: "args.name missing"},
        %ErrorDecl{code: :name_exists, message: "workspace name already taken"}
      ]
    }
  end

  test "help_line/1 renders one-line slash + args + description" do
    line = Render.help_line(sample_spec())
    assert line =~ "/workspace:new"
    assert line =~ "name=<…>"
    assert line =~ "[folder=<…>]"
    assert line =~ "create a new workspace"
  end

  test "help_line/1 with slash :none returns empty string" do
    spec = %Spec{sample_spec() | slash: :none}
    assert Render.help_line(spec) == ""
  end

  test "module_help/1 renders multi-line listing of all methods, sorted by kind" do
    spec_a = %Spec{sample_spec() | kind: :alpha, slash: "/r:alpha"}
    spec_b = %Spec{sample_spec() | kind: :beta, slash: "/r:beta"}
    spec_internal = %Spec{sample_spec() | kind: :internal, slash: :none}

    text = Render.module_help([spec_b, spec_a, spec_internal])

    # Sorted alphabetically by kind: alpha before beta
    alpha_pos = :binary.match(text, "/r:alpha") |> elem(0)
    beta_pos = :binary.match(text, "/r:beta") |> elem(0)
    assert alpha_pos < beta_pos

    # Internal kind (slash :none) is filtered out
    refute text =~ "internal"
  end

  test "error/3 returns a structured error map with the canonical message" do
    {:error, body} = Render.error(sample_spec(), :invalid_args)
    assert body["type"] == "invalid_args"
    assert body["message"] == "args.name missing"
  end

  test "error/3 with a detail map interpolates into the message via %{key} syntax" do
    spec = %Spec{
      sample_spec()
      | errors: [%ErrorDecl{code: :unknown, message: "unknown thing %{name}"}]
    }

    {:error, body} = Render.error(spec, :unknown, %{name: "foo"})
    assert body["message"] == "unknown thing foo"
  end

  test "error/3 interpolates integer detail values via to_string (regression: was producing codepoints)" do
    spec = %Spec{
      sample_spec()
      | errors: [%ErrorDecl{code: :timeout, message: "deadline %{ms} ms"}]
    }

    {:error, body} = Render.error(spec, :timeout, %{ms: 80})
    assert body["message"] == "deadline 80 ms"
  end

  test "error/3 interpolates atom detail values" do
    spec = %Spec{
      sample_spec()
      | errors: [%ErrorDecl{code: :code, message: "kind %{kind}"}]
    }

    {:error, body} = Render.error(spec, :code, %{kind: :workspace})
    assert body["message"] == "kind workspace"
  end

  test "error/3 with non-stringable detail value falls back to inspect" do
    spec = %Spec{
      sample_spec()
      | errors: [%ErrorDecl{code: :nested, message: "got %{detail}"}]
    }

    {:error, body} = Render.error(spec, :nested, %{detail: %{a: 1}})
    assert body["message"] =~ "got "
    assert body["message"] =~ "a: 1"
  end

  test "error/3 with placeholder for never-seen atom does not crash" do
    spec = %Spec{
      sample_spec()
      | errors: [
          %ErrorDecl{code: :code, message: "value %{__some_unique_unseen_atom_xyz123__}"}
        ]
    }

    {:error, body} = Render.error(spec, :code, %{})
    assert body["message"] =~ "%{__some_unique_unseen_atom_xyz123__}"
  end

  test "error/3 leaves untouched placeholders for missing detail keys" do
    spec = %Spec{
      sample_spec()
      | errors: [%ErrorDecl{code: :missing, message: "thing %{a} %{b}"}]
    }

    {:error, body} = Render.error(spec, :missing, %{a: "X"})
    assert body["message"] == "thing X %{b}"
  end

  test "error/3 with no declared message falls back to a generic message" do
    spec = %Spec{
      sample_spec()
      | errors: [%ErrorDecl{code: :bare_error, message: nil}]
    }

    {:error, body} = Render.error(spec, :bare_error)
    assert body["type"] == "bare_error"
    assert body["message"] =~ "bare_error"
    assert body["message"] =~ "workspace_new"
  end

  test "error/3 raises ArgumentError on undeclared error code" do
    assert_raise ArgumentError, ~r/undeclared error code :nope/, fn ->
      Render.error(sample_spec(), :nope)
    end
  end
end
