defmodule Esr.Commands.Workspace.Rename do
  @moduledoc """
  `/workspace rename` slash — change a workspace's display name.

  Caps + sessions reference the workspace by UUID and remain valid.
  For ESR-bound workspaces this also moves the on-disk directory.
  For repo-bound workspaces only the workspace.json + ETS index update.

  ## Args
      args: %{"name" => "old-name", "new_name" => "new-name"}

  ## Result
      {:ok, %{"old_name" => "old-name", "new_name" => "new-name", "id" => uuid}}
      {:error, %{"type" => "...", ...}}
  """

  use Esr.Commands.Meta

  command :workspace_rename do
    slash         "/workspace:rename"
    category      "Workspace"
    description   "改 workspace.name（id 不变；caps + sessions 引用按 UUID 不动）"
    permission    "workspace.create"
    requires_user_binding      true
    requires_workspace_binding false

    arg :name,     required: true, doc: "旧 workspace 名"
    arg :new_name, required: true, doc: "新 workspace 名"

    error :invalid_args,      "workspace_rename requires args.name and args.new_name"
    error :same_name,         "new name must differ from old name"
    error :invalid_name,      "name must be alphanumeric, with - or _, starting alnum"
    error :unknown_workspace, "workspace %{name} not found"
    error :rename_failed,     "rename failed: %{detail}"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Resource.Workspace.{Registry, NameIndex}

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => old, "new_name" => new}})
      when is_binary(old) and old != "" and is_binary(new) and new != "" do
    cond do
      old == new ->
        Render.error(__MODULE__.command_meta(), :same_name)

      not Regex.match?(@name_re, new) ->
        Render.error(__MODULE__.command_meta(), :invalid_name)

      true ->
        do_rename(old, new)
    end
  end

  def execute(_),
    do: Render.error(__MODULE__.command_meta(), :invalid_args)

  defp do_rename(old, new) do
    case lookup_id(old) do
      :not_found ->
        Render.error(__MODULE__.command_meta(), :unknown_workspace, %{name: old})

      {:ok, id} ->
        case Registry.rename(old, new) do
          :ok ->
            {:ok, %{"old_name" => old, "new_name" => new, "id" => id}}

          {:error, reason} ->
            Render.error(__MODULE__.command_meta(), :rename_failed, %{detail: inspect(reason)})
        end
    end
  end

  defp lookup_id(name) do
    NameIndex.id_for_name(:esr_workspace_name_index, name)
  end
end
