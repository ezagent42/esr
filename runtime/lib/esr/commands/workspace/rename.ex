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

  @behaviour Esr.Role.Control

  alias Esr.Resource.Workspace.{Registry, NameIndex}

  @name_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]*$/

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(cmd)

  def execute(%{"args" => %{"name" => old, "new_name" => new}})
      when is_binary(old) and old != "" and is_binary(new) and new != "" do
    cond do
      old == new ->
        {:error,
         %{
           "type" => "same_name",
           "message" => "new name must differ from old name"
         }}

      not Regex.match?(@name_re, new) ->
        {:error,
         %{
           "type" => "invalid_name",
           "name" => new,
           "message" => "name must be alphanumeric, with - or _, starting alnum"
         }}

      true ->
        do_rename(old, new)
    end
  end

  def execute(_),
    do:
      {:error,
       %{
         "type" => "invalid_args",
         "message" => "workspace_rename requires args.name and args.new_name"
       }}

  defp do_rename(old, new) do
    case lookup_id(old) do
      :not_found ->
        {:error, %{"type" => "unknown_workspace", "name" => old}}

      {:ok, id} ->
        case Registry.rename(old, new) do
          :ok ->
            {:ok, %{"old_name" => old, "new_name" => new, "id" => id}}

          {:error, reason} ->
            {:error,
             %{
               "type" => "rename_failed",
               "detail" => inspect(reason)
             }}
        end
    end
  end

  defp lookup_id(name) do
    NameIndex.id_for_name(:esr_workspace_name_index, name)
  end
end
