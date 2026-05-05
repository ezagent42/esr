defmodule Esr.Resource.Workspace.Describe do
  @moduledoc """
  Single source of truth for the security-filtered workspace data
  shape returned by the `describe_topology` MCP tool (cc plugin) and
  the `/workspace describe` slash command (operators).

  ## Security boundary

  This is the **only** function that decides what
  `describe_topology` exposes to the LLM (or to a slash-callable
  operator). It is an explicit allowlist — adding a new field to
  `%Workspace{}` does NOT auto-expose it.

  **Excluded by design:**
    - `owner` (esr-username — sensitive once paired with `users.yaml`'s
      feishu_ids; describe_topology is principal-agnostic on purpose)
    - `start_cmd` (operator config; could leak shell paths / args)
    - `env` (workspace env block — may carry secrets)

  The chats sub-map uses its own allowlist for the same reason. Never
  expose `users.yaml` data here — feishu open_ids / esr-username
  pairings are out-of-band identity material.

  Default-deny: if you need a new field, add it AND a regression test
  in `runtime/test/esr/entity_server_describe_topology_test.exs`.
  """

  alias Esr.Resource.Workspace.Registry, as: WsReg

  @type ok_data :: %{required(String.t()) => any()}
  @type result :: {:ok, ok_data()} | {:error, :unknown_workspace | :missing_workspace_name}

  @spec describe(String.t() | nil) :: result()
  def describe(ws_name) when is_binary(ws_name) and ws_name != "" do
    case WsReg.get(ws_name) do
      {:ok, ws} ->
        neighbours = resolve_neighbour_workspaces(ws)

        {:ok,
         %{
           "current_workspace" => filter_workspace(ws),
           "neighbor_workspaces" => Enum.map(neighbours, &filter_workspace/1)
         }}

      :error ->
        {:error, :unknown_workspace}
    end
  end

  def describe(_), do: {:error, :missing_workspace_name}

  defp filter_workspace(%WsReg.Workspace{} = ws) do
    %{
      "name" => ws.name,
      "role" => ws.role || "dev",
      "chats" =>
        Enum.map(ws.chats || [], fn chat ->
          if is_map(chat) do
            Map.take(chat, ["chat_id", "app_id", "kind", "name", "metadata"])
          else
            %{}
          end
        end),
      "neighbors_declared" => ws.neighbors || [],
      "metadata" => ws.metadata || %{}
    }
  end

  defp resolve_neighbour_workspaces(%WsReg.Workspace{neighbors: neighbours}) do
    neighbours
    |> Enum.flat_map(fn entry ->
      case String.split(entry || "", ":", parts: 2) do
        ["workspace", name] ->
          case WsReg.get(name) do
            {:ok, ws} -> [ws]
            :error -> []
          end

        _ ->
          []
      end
    end)
  end
end
