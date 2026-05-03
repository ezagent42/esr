defmodule Esr.Role do
  @moduledoc """
  Empty behavior markers used to tag every ESR-specific module with
  its **role category** (PR-21v, 2026-04-29).

  See `docs/notes/actor-role-vocabulary.md` for the full vocabulary
  and the 5-category taxonomy. The categories are:

  - `Esr.Role.Boundary`  — speaks to the outside world (foreign protocols, networks)
  - `Esr.Role.State`     — long-lived state container (singleton, registry, OS resource)
  - `Esr.Role.Pipeline`  — participates in the inbound/outbound message chain
  - `Esr.Role.Control`   — admin / configuration / lifecycle ops
  - `Esr.Role.OTP`       — pure OTP plumbing (supervisors), not an ESR-invented role

  Each child behavior is intentionally empty — it serves only as a
  compile-time marker. `grep -rn '@behaviour Esr.Role.Pipeline'` then
  enumerates every module of that category. Future PRs may upgrade a
  category to active enforcement (e.g. require all `*Guard` modules to
  implement `check/2`); the marker is the migration path.

  Modules NOT tagged with an `Esr.Role.*` behavior are framework imports
  (Phoenix `*Channel`/`*Socket`, OTP `Application`/`Supervisor` from
  outside the ESR taxonomy). The vocabulary doc explains why those are
  out of scope.
  """
end

defmodule Esr.Role.Boundary do
  @moduledoc """
  Marker for boundary-crossing modules: foreign-protocol bridges and
  network entry points. Examples: `Esr.Entities.FeishuAppAdapter`.

  Identifying property: speaks BOTH the ESR envelope shape on one side
  AND a foreign protocol (Feishu lark_oapi, MCP stdio, Phoenix WS,
  etc.) on the other. One per configured remote endpoint /
  `instance_id`.
  """
  @doc "Returns the role atom for this category. Optional — marker only."
  @callback __role__() :: :boundary
  @optional_callbacks __role__: 0
end

defmodule Esr.Role.State do
  @moduledoc """
  Marker for long-lived state containers. Includes:

  - `*Server` — top-level singleton with mutation-heavy state
  - `*Registry` — ETS-backed, read-mostly snapshot
  - `*Process` — wraps an OS process or external-resource lifecycle
  - `*Buffer` — bounded ring buffer / FIFO

  Identifying property: holds state that persists across many
  inbound messages; reads outnumber writes (registries) or the
  state IS the OS resource (processes).
  """
  @doc "Returns the role atom for this category. Optional — marker only."
  @callback __role__() :: :state
  @optional_callbacks __role__: 0
end

defmodule Esr.Role.Pipeline do
  @moduledoc """
  Marker for actor-pipeline participants — the inbound/outbound
  message chain. Includes:

  - `*Proxy` — per-entity local representative (one per chat/session)
  - `*Handler` — parses or dispatches one class of inbound
  - `*Guard` — gate: check + drop/pass + optional side effects
  - `*Router` — selects destination from a config table

  Identifying property: invoked once per inbound message; transforms
  or routes the message; output goes to the next pipeline node.
  """
  @doc "Returns the role atom for this category. Optional — marker only."
  @callback __role__() :: :pipeline
  @optional_callbacks __role__: 0
end

defmodule Esr.Role.Control do
  @moduledoc """
  Marker for admin / configuration / lifecycle modules. Includes:

  - `*Dispatcher` — async cmd-queue brain (admin commands)
  - `*Watcher` — FSEvents file-change observer
  - `*FileLoader` — yaml parse + atomic snapshot swap
  - `Commands.<Kind>` — single admin-command implementation
  - `*Bootstrap` — boot-time initialization

  Identifying property: operates on configuration / runtime state
  out-of-band from the inbound message chain. Watchers + Loaders
  reload configs; Dispatcher schedules cap-checked work.
  """
  @doc "Returns the role atom for this category. Optional — marker only."
  @callback __role__() :: :control
  @optional_callbacks __role__: 0
end

defmodule Esr.Role.OTP do
  @moduledoc """
  Marker for pure-OTP supervisors. Not an ESR-invented role —
  Supervisors ARE the OTP primitive. Tagged separately so that
  `grep -rn '@behaviour Esr.Role.OTP'` yields the supervisor tree
  inventory without conflating with the other 4 categories.

  Convention: only Supervisor modules get this marker. If a
  GenServer also happens to start child processes, it picks the
  category that describes its primary role (usually State or
  Control).
  """
  @doc "Returns the role atom for this category. Optional — marker only."
  @callback __role__() :: :otp
  @optional_callbacks __role__: 0
end
