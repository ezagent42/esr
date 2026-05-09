defmodule Esr.Commands.Session.Switch do
  @moduledoc """
  `Esr.Commands.Session.Switch` — flips the submitter's active
  routing target to the requested branch (spec §6.4 Session.Switch,
  plan DI-10 Task 20).

  Pure `routing.yaml` read-modify-write. The SlashHandler observes the
  change via its fs_watch and refreshes its in-memory routing map (no
  need to notify anything explicitly).

  ## Result

    * `{:ok, %{"active_branch" => branch}}` on success.
    * `{:error, %{"type" => "invalid_args"}}` — missing `args.branch` /
      `submitted_by`.
    * `{:error, %{"type" => "no_such_target"}}` — submitter has no
      entry in `routing.yaml`, or the branch isn't one of their
      `targets`. Session.New is the way to create a target; Switch
      refuses to materialize one out of thin air.
  """

  use Esr.Commands.Meta

  command :session_switch do
    slash         "/session:switch"
    category      "Sessions"
    description   "切换 chat 当前 session(不解绑其它);session=<uuid>"
    permission    nil
    requires_user_binding      true
    requires_workspace_binding false

    arg :session, required: true, doc: "session UUID v4"

    error :invalid_args,    "session_switch requires submitted_by + args.session (with chat_id + app_id) OR submitted_by + args.branch (legacy DI-10)"
    error :no_such_target,  "no such target"
    error :not_attached,    "session %{session_id} is not attached to this chat — use /session:attach session=%{session_id} first"
    error :switch_failed,   "could not switch chat-current session to %{session_id}: %{reason}"
    error :write_failed,    "routing.yaml write failed: %{detail}"
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()} | {:error, map()}

  alias Esr.Commands.Render

  @spec execute(map()) :: result()
  # Spec rev-4 §4.2 row 3: `/session:switch session=<uuid>` flips the chat's
  # current session WITHOUT unbinding the others. Requires chat_id + app_id
  # threaded by SlashHandler.inject_envelope_args/2. The UUID must already
  # be attached to this chat — Switch refuses to materialize bindings out
  # of thin air (use `/session:attach session=<uuid>` for that).
  def execute(%{
        "submitted_by" => submitter,
        "args" => %{"session" => session_uuid, "chat_id" => chat_id, "app_id" => app_id}
      })
      when is_binary(submitter) and is_binary(session_uuid) and session_uuid != "" and
             is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case Esr.Session.ChatRouting.Registry.set_current_session(chat_id, app_id, session_uuid) do
      :ok ->
        {:ok,
         %{
           "chat_id" => chat_id,
           "app_id" => app_id,
           "session_id" => session_uuid,
           "switched" => true
         }}

      {:error, :not_attached} ->
        Render.error(__MODULE__.command_meta(), :not_attached, %{session_id: session_uuid})

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :switch_failed, %{
          session_id: session_uuid,
          reason: inspect(reason)
        })
    end
  end

  def execute(%{"submitted_by" => submitter, "args" => %{"branch" => branch}})
      when is_binary(submitter) and is_binary(branch) and branch != "" do
    path = routing_yaml_path()

    case read_routing(path) do
      {:ok, current} ->
        principals = Map.get(current, "principals") || %{}
        principal = Map.get(principals, submitter)
        targets = (principal && Map.get(principal, "targets")) || %{}

        cond do
          is_nil(principal) ->
            Render.error(__MODULE__.command_meta(), :no_such_target)

          not Map.has_key?(targets, branch) ->
            Render.error(__MODULE__.command_meta(), :no_such_target)

          true ->
            write_active(path, current, principals, principal, submitter, branch)
        end

      {:error, :missing} ->
        Render.error(__MODULE__.command_meta(), :no_such_target)
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp read_routing(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> {:error, :missing}
    end
  end

  defp write_active(path, current, principals, principal, submitter, branch) do
    updated_principal = Map.put(principal, "active", branch)

    updated =
      Map.put(current, "principals", Map.put(principals, submitter, updated_principal))

    case Esr.Yaml.Writer.write(path, updated) do
      :ok ->
        {:ok, %{"active_branch" => branch}}

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :write_failed, %{detail: inspect(reason)})
    end
  end

  defp routing_yaml_path, do: Path.join(Esr.Paths.runtime_home(), "routing.yaml")
end
