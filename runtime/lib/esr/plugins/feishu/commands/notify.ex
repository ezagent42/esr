defmodule Esr.Plugins.Feishu.Commands.Notify do
  @moduledoc """
  `Esr.Plugins.Feishu.Commands.Notify` — emits a Feishu `reply` directive on
  behalf of the admin dispatcher (spec §6.4 Notify bullet).

  Called by `Esr.Admin.Dispatcher` inside a `Task.start` when a
  `notify`-kind command reaches the front of the queue. Pure function
  module (no GenServer) so it can be spawned and discarded.

  Routing (post-P2-16): iterates the admin-scope peers registered in
  `Esr.Session.Admin.Process` and finds the first
  `:feishu_app_adapter_<app_id>` entry. It broadcasts a `{:directive,
  directive}` to `adapter:feishu/<app_id>` on `EsrWeb.PubSub` — the
  Python Feishu adapter subprocess is subscribed there via
  `EsrWeb.AdapterChannel`. This replaces the pre-P2-16 lookup through
  the now-deleted `Esr.AdapterHub.Registry`.

  Result shape:
    * `{:ok, %{"delivered_at" => <iso8601>}}` on successful broadcast.
    * `{:error, %{"type" => "no_feishu_adapter"}}` when no Feishu
      adapter is registered — callers surface this as a failed command
      without retry (operator action required).
  """

  use Esr.Commands.Meta

  command :feishu_notify do
    slash         :none
    category      "Plugins"
    description   "向 feishu open_id 发一条 reply（admin notify path）"
    permission    "feishu/notify-send"
    requires_user_binding      false
    requires_workspace_binding false

    arg :to,   required: true, doc: "目标 feishu open_id"
    arg :text, required: true, doc: "回复文本"

    error :invalid_args,        "notify requires args.to and args.text"
    error :no_feishu_adapter,   "no feishu adapter registered"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"to" => to_open_id, "text" => text}} = _cmd)
      when is_binary(to_open_id) and is_binary(text) do
    case find_feishu_topic() do
      {:ok, topic} ->
        directive = %{
          "kind" => "reply",
          "args" => %{
            "receive_id" => to_open_id,
            "receive_id_type" => "open_id",
            "text" => text
          }
        }

        :ok = Phoenix.PubSub.broadcast(EsrWeb.PubSub, topic, {:directive, directive})

        {:ok, %{"delivered_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}

      :error ->
        Render.error(__MODULE__.command_meta(), :no_feishu_adapter)
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  # Find the first `adapter:feishu/<app_id>` topic by iterating the
  # Scope.Admin.Process admin-peer map (post-P2-16 replacement for
  # `Esr.AdapterHub.Registry.list/0`). Admin-peer names are atoms of
  # the form `:feishu_app_adapter_<app_id>`.
  @spec find_feishu_topic() :: {:ok, String.t()} | :error
  defp find_feishu_topic do
    case Process.whereis(Esr.Session.Admin.Process) do
      nil ->
        :error

      _pid ->
        Esr.Session.Admin.Process.list_admin_peers()
        |> Enum.find_value(:error, fn {name, _pid} ->
          case Atom.to_string(name) do
            "feishu_app_adapter_" <> app_id ->
              {:ok, "adapter:feishu/" <> app_id}

            _ ->
              nil
          end
        end)
    end
  end
end
