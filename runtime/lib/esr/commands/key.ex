defmodule Esr.Commands.Key do
  @moduledoc """
  `/key <keyspec> [<keyspec> …]` — send special keystrokes to the
  chat-current session's PTY (PR-24 step 2 follow-up).

  The boot bridge (`Esr.Plugins.Feishu.FeishuChatProxy`) routes plain Feishu
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

  use Esr.Commands.Meta

  command :key do
    slash         :none
    category      "PTY"
    description   "把特殊键盘输入（up/down/enter/esc/tab/c-X 等）发到 chat-current session 的 PTY"
    permission    nil
    requires_user_binding      false
    requires_workspace_binding false

    arg :keys, required: true, doc: "key spec(s); 例 up enter c-c esc"

    error :missing_keys,
          "usage: /key <keyspec> [<keyspec> …]   examples: /key up enter   /key c-c   /key esc esc"

    error :missing_chat_context,
          "/key needs chat_id + app_id from the inbound envelope"

    error :no_session,
          "no chat-current session in this chat — start one with /new-session first"

    error :unknown_key,
          "unknown key '%{key}'. supported: up/down/left/right, enter, esc, tab, space, bs, c-<letter>"

    error :invalid_args, "/key requires args map with keys + chat context"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render
  alias Esr.Session.ChatRouting.Registry, as: ChatScopeRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) do
    chat_id = Map.get(args, "chat_id", "")
    app_id = Map.get(args, "app_id", "")
    keyspec = Map.get(args, "keys", "") |> to_string() |> String.trim()

    cond do
      keyspec == "" ->
        Render.error(__MODULE__.command_meta(), :missing_keys)

      chat_id == "" or app_id == "" ->
        Render.error(__MODULE__.command_meta(), :missing_chat_context)

      true ->
        do_execute(chat_id, app_id, keyspec)
    end
  end

  def execute(_), do: Render.error(__MODULE__.command_meta(), :invalid_args)

  defp do_execute(chat_id, app_id, keyspec) do
    case translate_all(keyspec) do
      {:ok, bytes} ->
        case ChatScopeRegistry.lookup_by_chat(chat_id, app_id) do
          {:ok, sid, _refs} ->
            # Phase A.4b: PtyProcess.write/2 looks up "pty:<actor_id>"
            # post-Phase-A.4. For multi-agent sessions, resolve the
            # primary agent's pty_actor_id via InstanceRegistry; for
            # single-agent sessions (no InstanceRegistry row), PtyProcess
            # falls back to `actor_id ||= session_id` so a session_id
            # lookup still succeeds.
            pty_id = resolve_pty_actor_id(sid)
            _ = Esr.Entity.PtyProcess.write(pty_id, bytes)
            {:ok, %{"text" => "🎹 sent #{byte_size(bytes)} byte(s) to PTY"}}

          :not_found ->
            Render.error(__MODULE__.command_meta(), :no_session)
        end

      {:error, bad} ->
        Render.error(__MODULE__.command_meta(), :unknown_key, %{key: bad})
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

  # Phase A.4b — resolve the primary agent's pty_actor_id for the
  # session, falling back to session_id when no InstanceRegistry row
  # exists (single-agent / AgentSpawner path; PtyProcess.init's
  # `actor_id ||= session_id` makes "pty:<session_id>" the lookup key
  # in that case).
  defp resolve_pty_actor_id(session_id) do
    case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
      {:ok, name} ->
        case Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(session_id, name) do
          {:ok, aid} -> aid
          :not_found -> session_id
        end

      :not_found ->
        session_id
    end
  rescue
    _ -> session_id
  catch
    :exit, _ -> session_id
  end
end
