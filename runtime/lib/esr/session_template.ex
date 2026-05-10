defmodule Esr.SessionTemplate do
  @moduledoc """
  Parsed in-memory shape of a session template (`template.yaml`) per
  spec §5.3.

  A SessionTemplate declares **how a session is wired**: which
  channels are instantiated, which agents run, and how messages flow
  between them. Parsed at bundle/operator-yaml load time by
  `Esr.SessionTemplate.Parser`; consumed at session creation
  (Phase 5) by `/session:new`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`
  §5.3.

  ## Field shapes

    * `schema_version` — must be `1` (loud-fail on mismatch).
    * `name` — required when registered standalone (operator-shipped
      ad-hoc). For bundle-shipped templates the **bundle name** is the
      registration key, but the template's `name:` (if provided) is
      preserved on the struct for inspection.
    * `description` — optional.
    * `dependencies` — `%{plugins: [String.t()], bundles: [String.t()]}`.
      Same shape as `Esr.Bundle.Manifest.dependencies`. For
      bundle-shipped templates this is set from the bundle's manifest;
      for operator ad-hoc templates the yaml carries it inline.
    * `channels` — list of `%{alias, kind, config}`. `kind` is
      `<plugin>.<channel_name>`; `config` is a string-keyed map.
    * `agents` — list of `%{kind, name, consumes}`. `kind` is
      `<plugin>.<agent_kind>`; `consumes` is a list of channel
      `alias`es declared in the same template.
    * `flow` — `%{inbound: [...], outbound: [...]}`. Inbound entries
      have `%{source, pipeline}`; outbound entries have `%{source, sink}`.
  """

  defstruct [
    :schema_version,
    :name,
    :description,
    :dependencies,
    :channels,
    :agents,
    :flow
  ]

  @type channel :: %{alias: String.t(), kind: String.t(), config: map()}
  @type agent :: %{kind: String.t(), name: String.t(), consumes: [String.t()]}

  @type pipeline_entry ::
          {:builtin, atom()}
          | {:module, module()}
          | {:unresolved, String.t()}

  @type inbound_entry :: %{source: String.t(), pipeline: [pipeline_entry()]}
  @type outbound_entry :: %{source: String.t(), sink: String.t()}

  @type flow :: %{inbound: [inbound_entry()], outbound: [outbound_entry()]}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          name: String.t() | nil,
          description: String.t(),
          dependencies: %{plugins: [String.t()], bundles: [String.t()]},
          channels: [channel()],
          agents: [agent()],
          flow: flow()
        }
end
