defmodule Esr.Commands.Meta do
  @moduledoc """
  DSL + behaviour for declaring a command's grammar (slash + CLI shape,
  args, errors, help text) in one place. The DSL block expands at compile
  time into a `command_meta/0` function returning a `%Spec{}` struct.

  Every command module that adopts the DSL via `use Esr.Commands.Meta`
  must implement BOTH callbacks:

    * `command_meta/0` — returns the compile-time grammar spec
    * `execute/1` — runs the command (operator-facing entry point)

  Consumers:
    * `Esr.Commands.Render` — turns specs into help lines / module help /
      error maps.
    * `Mix.Tasks.Esr.GenSlashRoutes` — emits slash-routes.default.yaml.
    * `Mix.Tasks.Esr.GenCommandDocs` — emits docs/grammar/{commands,errors}.md.
    * `Mix.Tasks.Esr.CheckCommandDocs` — CI drift gate.

  History: spec 2026-05-09. Phase 1 (this commit) ships the behaviour +
  DSL. Phase 2 converts Workspace.New as a canary; Phase 3 converts the
  remaining ~76 command modules.

  Note: `execute/1` is declared here (not on `Esr.Role.Control`) because
  Role.Control is a broad marker for commands + watchers + file_loaders +
  bootstraps, and only the commands category has `execute/1`.
  """

  @callback command_meta() :: Esr.Commands.Meta.Spec.t()
  @callback execute(map()) :: {:ok, map()} | {:error, map()}

  defmodule Spec do
    @moduledoc "Compiled command grammar; the return shape of command_meta/0."

    @type t :: %__MODULE__{
            kind: atom(),
            slash: String.t() | :none,
            category: String.t(),
            description: String.t(),
            permission: String.t() | nil,
            requires_user_binding: boolean(),
            requires_workspace_binding: boolean(),
            args: [Esr.Commands.Meta.Arg.t()],
            errors: [Esr.Commands.Meta.ErrorDecl.t()]
          }

    defstruct kind: nil,
              slash: nil,
              category: "其他",
              description: "",
              permission: nil,
              requires_user_binding: false,
              requires_workspace_binding: false,
              args: [],
              errors: []
  end

  defmodule Arg do
    @moduledoc "Single command arg declaration."

    @type t :: %__MODULE__{
            name: atom(),
            required: boolean(),
            default: term(),
            doc: String.t() | nil
          }

    defstruct name: nil, required: false, default: nil, doc: nil
  end

  defmodule ErrorDecl do
    @moduledoc "Single error code + canonical message."

    @type t :: %__MODULE__{
            code: atom(),
            message: String.t() | nil
          }

    defstruct code: nil, message: nil
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Esr.Commands.Meta, only: [command: 2]
      @behaviour Esr.Commands.Meta
    end
  end

  defmacro command(kind, do: block) when is_atom(kind) do
    quote do
      Module.register_attribute(__MODULE__, :__cmd_args__, accumulate: true)
      Module.register_attribute(__MODULE__, :__cmd_errors__, accumulate: true)
      @__cmd_kind unquote(kind)
      @__cmd_slash nil
      @__cmd_category "其他"
      @__cmd_description ""
      @__cmd_permission nil
      @__cmd_requires_user false
      @__cmd_requires_ws false

      import Esr.Commands.Meta,
        only: [
          slash: 1,
          category: 1,
          description: 1,
          permission: 1,
          requires_user_binding: 1,
          requires_workspace_binding: 1,
          arg: 2,
          error: 1,
          error: 2
        ]

      unquote(block)

      Esr.Commands.Meta.__validate_no_duplicate_errors__!(
        __MODULE__,
        @__cmd_errors__
      )

      def command_meta do
        %Esr.Commands.Meta.Spec{
          kind: @__cmd_kind,
          slash: @__cmd_slash,
          category: @__cmd_category,
          description: @__cmd_description,
          permission: @__cmd_permission,
          requires_user_binding: @__cmd_requires_user,
          requires_workspace_binding: @__cmd_requires_ws,
          args: Enum.reverse(@__cmd_args__),
          errors: Enum.reverse(@__cmd_errors__)
        }
      end
    end
  end

  defmacro slash(value),       do: quote(do: @__cmd_slash unquote(value))
  defmacro category(value),    do: quote(do: @__cmd_category unquote(value))
  defmacro description(value), do: quote(do: @__cmd_description unquote(value))
  defmacro permission(value),  do: quote(do: @__cmd_permission unquote(value))
  defmacro requires_user_binding(value),      do: quote(do: @__cmd_requires_user unquote(value))
  defmacro requires_workspace_binding(value), do: quote(do: @__cmd_requires_ws unquote(value))

  defmacro arg(name, opts) when is_atom(name) and is_list(opts) do
    quote do
      @__cmd_args__ %Esr.Commands.Meta.Arg{
        name: unquote(name),
        required: Keyword.get(unquote(opts), :required, false),
        default: Keyword.get(unquote(opts), :default, nil),
        doc: Keyword.get(unquote(opts), :doc, nil)
      }
    end
  end

  defmacro error(code) when is_atom(code) do
    quote do
      @__cmd_errors__ %Esr.Commands.Meta.ErrorDecl{code: unquote(code), message: nil}
    end
  end

  defmacro error(code, message) when is_atom(code) and is_binary(message) do
    quote do
      @__cmd_errors__ %Esr.Commands.Meta.ErrorDecl{
        code: unquote(code),
        message: unquote(message)
      }
    end
  end

  @doc false
  def __validate_no_duplicate_errors__!(module, errors) do
    codes = Enum.map(errors, & &1.code)

    case codes -- Enum.uniq(codes) do
      [] ->
        :ok

      dups ->
        raise CompileError,
          file: to_string(module),
          line: 1,
          description: "duplicate error code #{inspect(hd(dups))} in #{inspect(module)}"
    end
  end
end
