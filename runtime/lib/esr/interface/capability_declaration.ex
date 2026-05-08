defmodule Esr.Interface.CapabilityDeclaration do
  @moduledoc """
  Capability declaration contract: any module that declares the *existence*
  of a capability (by name + description + required-for) implements this
  Interface.

  Per session.md §六 Capability:
  > Two-state Resource:
  > - **Declarative**: cap is declared in code
  > - **Granted**: grant relationship lives in CapabilityRegistry

  This Interface is the *declarative* face. The granted face is
  `Esr.Interface.Grant`.

  Current implementers (post-R9):
    - none — declarations today are scattered as `permissions/0` callbacks
      on Handler-flavored Entity modules + `permissions.yaml` runtime data.

  Future implementers (when concrete capability declaration modules land,
  e.g. for new agents or plugins per `docs/futures/todo.md` plugin spec):
    each `Esr.Capabilities.<Name>` module declares its cap shape via
    these callbacks.

  See session.md §七 (CapabilityDeclarationInterface) and
  `docs/notes/structural-refactor-plan-r4-r11.md` §四-R9.
  """

  @doc "The canonical capability name as a string (e.g. `\"session:default/create\"`)."
  @callback name() :: String.t()

  @doc "Human-readable description shown in /doctor and grant UIs."
  @callback description() :: String.t()

  @doc """
  List of operation prefixes that require this capability. Format:
  `[\"<resource>:<scope>/<operation>\"]`. Used by the dispatcher to
  decide whether a principal's grants cover a requested operation.
  """
  @callback required_for() :: [String.t()]
end
