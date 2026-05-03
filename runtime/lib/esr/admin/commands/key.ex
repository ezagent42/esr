defmodule Esr.Admin.Commands.Key do
  @moduledoc """
  `/key <keyspec> [<keyspec> …]` — send special keystrokes to the
  chat-current session's PTY (PR-24 step 2 follow-up).

  The boot bridge (`Esr.Entity.FeishuChatProxy`) routes plain Feishu
  text + `\\r` into the PTY when `cc_mcp_ready=false`, which covers
  most boot dialogs ("type 1 + Enter"). For dialogs that need cursor
  navigation, `Esc`, or control characters, this command translates
  named keys into the appropriate byte sequences.

  ## Keyspec syntax

  - `up` / `down` / `left` / `right`  → arrow keys
  - `enter` / `return`                → `\\r`
  - `esc` / `escape`                  → `\\e`
  - `tab`                             → `\\t`
  - `space`                           → ` `
  - `bs` / `backspace`                → `\\b`
  - `c-X` (X = letter)                → control-X (0x01..0x1A)

  Multiple keys are space-separated and sent as a single PTY write,
  e.g. `/key down down enter` selects two-down + confirm in a TUI menu.

  Unknown tokens cause the whole command to reject — better than
  silently dropping a typo and leaving the operator wondering.
  """

  @behaviour Esr.Role.Control

  alias Esr.SessionRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) do
    chat_id = Map.get(args, "chat_id", "")
    app_id = Map.get(args, "app_id", "")
    keyspec = Map.get(args, "keys", "") |> to_string() |> String.trim()

    cond do
      keyspec == "" ->
        {:error,
         %{
           "type" => "missing_keys",
           "message" =>
             "usage: /key <keyspec> [<keyspec> …]   examples: /key up enter   /key c-c   /key esc esc"
         }}

      chat_id == "" or app_id == "" ->
        {:error,
         %{
           "type" => "missing_chat_context",
           "message" => "/key needs chat_id + app_id from the inbound envelope"
         }}

      true ->
        do_execute(chat_id, app_id, keyspec)
    end
  end

  def execute(_), do: {:error, %{"type" => "invalid_args"}}

  defp do_execute(chat_id, app_id, keyspec) do
    case translate_all(keyspec) do
      {:ok, bytes} ->
        case SessionRegistry.lookup_by_chat(chat_id, app_id) do
          {:ok, sid, _refs} ->
            _ = Esr.Entity.PtyProcess.write(sid, bytes)
            {:ok, %{"text" => "🎹 sent #{byte_size(bytes)} byte(s) to PTY"}}

          :not_found ->
            {:error,
             %{
               "type" => "no_session",
               "message" =>
                 "no chat-current session in this chat — start one with /new-session first"
             }}
        end

      {:error, bad} ->
        {:error,
         %{
           "type" => "unknown_key",
           "key" => bad,
           "message" =>
             "unknown key '#{bad}'. supported: up/down/left/right, enter, esc, tab, " <>
               "space, bs, c-<letter>"
         }}
    end
  end

  @spec translate_all(String.t()) :: {:ok, binary()} | {:error, String.t()}
  defp translate_all(keyspec) do
    keyspec
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn tok, {:ok, acc} ->
      case translate(tok) do
        {:ok, bytes} -> {:cont, {:ok, [acc | bytes]}}
        :error -> {:halt, {:error, tok}}
      end
    end)
    |> case do
      {:ok, iolist} -> {:ok, IO.iodata_to_binary(iolist)}
      {:error, bad} -> {:error, bad}
    end
  end

  defp translate(tok), do: tok |> String.downcase() |> do_translate()

  defp do_translate("up"), do: {:ok, "\e[A"}
  defp do_translate("down"), do: {:ok, "\e[B"}
  defp do_translate("right"), do: {:ok, "\e[C"}
  defp do_translate("left"), do: {:ok, "\e[D"}
  defp do_translate("enter"), do: {:ok, "\r"}
  defp do_translate("return"), do: {:ok, "\r"}
  defp do_translate("esc"), do: {:ok, "\e"}
  defp do_translate("escape"), do: {:ok, "\e"}
  defp do_translate("tab"), do: {:ok, "\t"}
  defp do_translate("space"), do: {:ok, " "}
  defp do_translate("bs"), do: {:ok, "\b"}
  defp do_translate("backspace"), do: {:ok, "\b"}

  defp do_translate(<<"c-", letter::utf8>>) when letter in ?a..?z do
    {:ok, <<letter - ?a + 1>>}
  end

  defp do_translate(<<"c-", letter::utf8>>) when letter in ?A..?Z do
    {:ok, <<letter - ?A + 1>>}
  end

  defp do_translate(_), do: :error
end
