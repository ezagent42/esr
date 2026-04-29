defmodule Esr.Admin.Commands.Workspace.Info do
  @moduledoc """
  `Esr.Admin.Commands.Workspace.Info` — display the configuration of
  one workspace (PR-21j). Dispatcher kind `workspace_info`.

  ## Args

      args: %{"workspace" => "esr-dev"}

  When `workspace` is omitted but the slash command has a chat
  context, `SlashHandler` resolves the chat to a workspace and fills
  it in. Direct admin-CLI submits must specify it.

  ## Result shape

      {:ok, %{
        "name"     => "esr-dev",
        "owner"    => "linyilun",
        "root"     => "/Users/h2oslabs/Workspace/esr",
        "role"     => "dev",
        "chats"    => [%{"chat_id" => "oc_xxx", "app_id" => "cli_yyy", ...}],
        "neighbors"=> ["workspace:esr-kanban", ...],
        "metadata" => %{"purpose" => "...", ...}
      }}

  Read-only — touches `Esr.Workspaces.Registry` only.
  """

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"workspace" => ws}}) when is_binary(ws) and ws != "" do
    case Esr.Workspaces.Registry.get(ws) do
      {:ok, w} ->
        {:ok,
         %{
           "name" => w.name,
           "owner" => w.owner,
           "root" => w.root,
           "role" => w.role,
           "chats" => w.chats,
           "neighbors" => w.neighbors,
           "metadata" => w.metadata
         }}

      :error ->
        {:error, %{"type" => "unknown_workspace", "workspace" => ws}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "workspace_info requires args.workspace (non-empty string)"
     }}
  end
end
