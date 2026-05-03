defmodule Esr.Entity.Proxy do
  @moduledoc """
  Stateless forwarder Peer.

  Compile-time restricted: a module using `Esr.Entity.Proxy` cannot
  define `handle_call/3` or `handle_cast/2` — doing so raises a
  compile error.

  Optional `@required_cap "<permission_str>"` module attribute (literal
  string only; runtime templates deferred) injects a capability-check
  wrapper around `forward/2`. The wrapper:

    1. Reads `ctx.principal_id` (must be a binary).
    2. Checks the capability. P3-3a: if `ctx.session_process_pid` is
       present and alive, the check goes to `Esr.Scope.Process.has?/2`
       via that pid (local projection, no global GenServer contention);
       otherwise it falls back to `Esr.Capabilities.has?/2` on the
       global snapshot.
    3. On false → returns `{:drop, :cap_denied}`.
    4. On true → delegates to the user's `forward/2` body.
       If the body's return is `:ok` or `{:ok, _}`, the wrapper additionally
       checks the `ctx.target_pid` is alive before the send already happened
       inside `forward/2`; dead-target handling is the body's responsibility
       (idiomatic pattern: `send(ctx.target_pid, msg)` then `:ok`, and the
       caller handles `{:drop, :target_unavailable}` via a DOWN monitor).

  Test-time override: set `Process.put(:esr_cap_test_override, fn pid, perm -> bool end)`
  to bypass the capability check in unit tests. Production never reads
  this key.

  See spec §3.1, §3.6, §6 Risk B, and
  `docs/futures/peer-session-capability-projection.md` for the
  per-Session projection rationale.
  """

  @callback forward(msg :: term(), ctx :: map()) ::
              :ok | {:ok, term()} | {:drop, reason :: atom()}

  @forbidden [{:handle_call, 3}, {:handle_cast, 2}]

  defmacro __using__(_opts) do
    quote do
      use Esr.Entity, kind: :proxy
      @behaviour Esr.Entity.Proxy
      @before_compile Esr.Entity.Proxy
    end
  end

  defmacro __before_compile__(env) do
    defined = Module.definitions_in(env.module, :def)

    offenders = for fa <- @forbidden, fa in defined, do: fa

    if offenders != [] do
      msg =
        "Esr.Entity.Proxy module #{inspect(env.module)} cannot define stateful callbacks. " <>
          "Found: #{inspect(offenders)}. Use Esr.Entity.Stateful if you need state."

      raise CompileError, description: msg
    end

    cap = Module.get_attribute(env.module, :required_cap)

    if is_binary(cap) do
      quote do
        defoverridable forward: 2

        def forward(msg, ctx) do
          principal_id = Map.get(ctx, :principal_id)

          check = Esr.Entity.Proxy.__resolve_cap_check__(ctx)

          cond do
            not is_binary(principal_id) ->
              {:drop, :cap_denied}

            check.(principal_id, unquote(cap)) ->
              super(msg, ctx)

            true ->
              {:drop, :cap_denied}
          end
        end
      end
    else
      :ok
    end
  end

  @doc false
  # Resolves the capability-check function for a given ctx. Public
  # (per `@doc false`) only so the macro-expanded forward/2 can call
  # it; not part of the user-facing API.
  #
  # Resolution order:
  #   1. Test override (`Process.put(:esr_cap_test_override, ...)`)
  #   2. Per-session local projection via `ctx.session_process_pid`
  #      when present and the process is alive (P3-3a).
  #   3. Global `Esr.Capabilities.has?/2` fallback (admin-plane or
  #      pre-PR-3 test ctx without session_process_pid).
  def __resolve_cap_check__(ctx) do
    case Process.get(:esr_cap_test_override) do
      fun when is_function(fun, 2) ->
        fun

      _ ->
        case Map.get(ctx, :session_process_pid) do
          pid when is_pid(pid) ->
            if Process.alive?(pid) do
              # P6-A2: has?/2 is a zero-hop :persistent_term read, no
              # GenServer round-trip. Keep the `Process.alive?` guard
              # to preserve the "fall back to global when the session
              # is gone" semantic — on normal shutdown terminate/2
              # erases the persistent_term entry (so a stale pid
              # would read `[]` anyway), but hard crashes may leave
              # stale entries that the global fallback avoids.
              case Map.get(ctx, :session_id) do
                sid when is_binary(sid) ->
                  fn _principal_id, permission ->
                    Esr.Scope.Process.has?(sid, permission)
                  end

                _ ->
                  &Esr.Capabilities.has?/2
              end
            else
              &Esr.Capabilities.has?/2
            end

          _ ->
            &Esr.Capabilities.has?/2
        end
    end
  end
end
