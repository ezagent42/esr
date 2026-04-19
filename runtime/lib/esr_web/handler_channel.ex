defmodule EsrWeb.HandlerChannel do
  @moduledoc """
  Phoenix.Channel for a single handler-worker topic
  ``handler:<module>/<worker_id>`` (PRD 01 F12).

  Inbound ``handler_reply`` envelopes are broadcast on Phoenix.PubSub
  at topic ``handler_reply:<id>``. ``Esr.HandlerRouter.call`` (F11)
  subscribes to that topic before pushing its ``handler_call`` and
  delivers the reply to the calling process (or times out).

  The channel deliberately does no state tracking — correlation lives
  in the caller, and the channel's only job is to dispatch the frame.
  """

  use Phoenix.Channel

  @impl Phoenix.Channel
  def join("handler:" <> rest = topic, _payload, socket) do
    case String.split(rest, "/") do
      [_module, _worker_id] ->
        {:ok, assign(socket, :topic, topic)}

      _ ->
        {:error, %{reason: "invalid topic"}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid topic"}}
  end

  # Envelope dispatch — Python handler_worker pushes everything as a
  # single "envelope" event; route by kind.
  @impl Phoenix.Channel
  def handle_in("envelope", %{"kind" => "handler_reply"} = envelope, socket) do
    handle_in("handler_reply", envelope, socket)
  end

  def handle_in("envelope", _envelope, socket) do
    {:reply, {:error, %{reason: "envelope missing/unknown kind"}}, socket}
  end

  def handle_in("handler_reply", %{"id" => id} = envelope, socket) do
    Phoenix.PubSub.broadcast(
      EsrWeb.PubSub,
      "handler_reply:" <> id,
      {:handler_reply, envelope}
    )

    {:reply, :ok, socket}
  end

  def handle_in("handler_reply", _envelope, socket) do
    {:reply, {:error, %{reason: "handler_reply missing id"}}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unhandled event: #{event}"}}, socket}
  end
end
