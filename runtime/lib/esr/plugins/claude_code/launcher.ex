defmodule Esr.Plugins.ClaudeCode.Launcher do
  @moduledoc """
  Elixir-native launcher for the Claude Code agent process.

  Replaces `scripts/esr-cc.sh` (deleted Phase 8). All env-var construction
  and pre-spawn filesystem operations are performed here in Elixir before
  PtyProcess is asked to exec the `claude` binary.

  ## Responsibilities

  | Was in `esr-cc.sh`                      | Moves to                                  |
  |------------------------------------------|-------------------------------------------|
  | `http_proxy` / `https_proxy` / `no_proxy` | `build_env/1` via plugin config          |
  | `ESR_ESRD_URL`                           | `build_env/1` via plugin config           |
  | `.mcp.json` write                        | `write_mcp_json/1`                        |
  | `mkdir -p "$cwd"`                        | `prepare_spawn/1` calls `File.mkdir_p/1`  |
  | `exec claude` binary                     | `spawn_cmd/1` returns argv list           |

  Spec: `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` §6
  (shell-script deletion map).
  """

  alias Esr.Plugin.Config

  @claude_binary System.find_executable("claude") || "claude"

  @doc """
  Build the OS environment keyword list to pass to PtyProcess.

  Only injects env vars for non-empty plugin config values.
  No fallback defaults — let-it-crash policy: if a required key is absent
  from plugin config the call site is misconfigured and should crash loudly.

  ## Options

    * `:plugin_config` — pre-resolved config map (from `Plugin.Config.resolve/2`).
      Must be a `%{String.t() => String.t()}` map. Required.
    * `:session_id` — session UUID string. Required.
  """
  @spec build_env(keyword()) :: keyword()
  def build_env(opts) do
    config     = Keyword.fetch!(opts, :plugin_config)
    session_id = Keyword.fetch!(opts, :session_id)

    [ESR_SESSION_ID: session_id]
    |> maybe_put(:http_proxy,  config["http_proxy"])
    |> maybe_put(:HTTP_PROXY,  config["http_proxy"])
    |> maybe_put(:https_proxy, config["https_proxy"])
    |> maybe_put(:HTTPS_PROXY, config["https_proxy"])
    |> maybe_put(:no_proxy,    config["no_proxy"])
    |> maybe_put(:NO_PROXY,    config["no_proxy"])
    |> maybe_put(:ESR_ESRD_URL, config["esrd_url"])
  end

  @doc """
  Write `.mcp.json` into `cwd` before spawning the PTY.

  The written file uses the HTTP transport (scheme flip from `ws://` →
  `http://` / `wss://` → `https://`) so Claude Code's MCP client can
  reach esrd's HTTP MCP endpoint.

  ## Options

    * `:cwd`        — workspace directory. Required.
    * `:esrd_url`   — WebSocket URL of the ESRD host (e.g. `ws://127.0.0.1:4001`). Required.
    * `:session_id` — session UUID string. Required.
  """
  @spec write_mcp_json(keyword()) :: :ok | {:error, term()}
  def write_mcp_json(opts) do
    cwd        = Keyword.fetch!(opts, :cwd)
    esrd_url   = Keyword.fetch!(opts, :esrd_url)
    session_id = Keyword.fetch!(opts, :session_id)

    # Flip ws:// → http:// (wss:// → https://) for the HTTP MCP transport.
    http_base =
      esrd_url
      |> String.replace(~r/^ws:\/\//, "http://")
      |> String.replace(~r/^wss:\/\//, "https://")

    content =
      Jason.encode!(
        %{
          "mcpServers" => %{
            "esr-channel" => %{
              "type" => "http",
              "url"  => "#{http_base}/mcp/#{session_id}"
            }
          }
        },
        pretty: true
      )

    mcp_path = Path.join(cwd, ".mcp.json")
    File.write(mcp_path, content)
  end

  @doc """
  Return the argv list for the claude binary.

  Does NOT exec — PtyProcess calls exec. Flags that were in esr-cc.sh
  (`--permission-mode auto`, `--dangerously-load-development-channels`,
  `--mcp-config .mcp.json`, `--add-dir`) are preserved here.

  ## Options

    * `:cwd`  — workspace directory (used for `--add-dir`). Optional.
    * `:role` — workspace role string (used for `--settings` if a role
                settings file exists). Optional.
  """
  @spec spawn_cmd(keyword()) :: [String.t()]
  def spawn_cmd(opts) do
    cwd  = Keyword.get(opts, :cwd)
    role = Keyword.get(opts, :role, "dev")

    flags = [
      "--permission-mode", "auto",
      "--dangerously-load-development-channels", "server:esr-channel",
      "--mcp-config", ".mcp.json"
    ]

    flags = if is_binary(cwd) and cwd != "" do
      flags ++ ["--add-dir", cwd]
    else
      flags
    end

    # Role-specific settings file (same logic as the old esr-cc.sh).
    flags =
      case settings_file_for_role(role) do
        {:ok, path} -> flags ++ ["--settings", path]
        :error      -> flags
      end

    [@claude_binary | flags]
  end

  @doc """
  Full pre-spawn sequence:

    1. `mkdir_p` workspace cwd
    2. Write `.mcp.json`
    3. Return `{cmd, env}` tuple for PtyProcess

  ## Options

    * `:cwd`          — workspace directory. Required.
    * `:session_id`   — session UUID string. Required.
    * `:plugin_config` — pre-resolved config map. When absent, calls
                         `Plugin.Config.resolve("claude_code", opts)`.
    * `:user_uuid`    — forwarded to `Plugin.Config.resolve/2` when
                        `:plugin_config` is not supplied. Optional.
    * `:workspace_id` — forwarded to `Plugin.Config.resolve/2` when
                        `:plugin_config` is not supplied. Optional.
    * `:role`         — workspace role for settings file lookup. Optional.
  """
  @spec prepare_spawn(keyword()) ::
          {:ok, {[String.t()], keyword()}} | {:error, term()}
  def prepare_spawn(opts) do
    cwd        = Keyword.fetch!(opts, :cwd)
    session_id = Keyword.fetch!(opts, :session_id)
    config     = resolve_plugin_config(opts)

    with :ok <- File.mkdir_p(cwd),
         :ok <-
           write_mcp_json(
             cwd: cwd,
             esrd_url: config["esrd_url"] || "",
             session_id: session_id
           ) do
      env = build_env(plugin_config: config, session_id: session_id)
      cmd = spawn_cmd(Keyword.take(opts, [:cwd, :role]))
      {:ok, {cmd, env}}
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp maybe_put(env, _key, value) when is_nil(value), do: env
  defp maybe_put(env, _key, ""),    do: env
  defp maybe_put(env, key, value),  do: Keyword.put(env, key, value)

  defp resolve_plugin_config(opts) do
    case Keyword.fetch(opts, :plugin_config) do
      {:ok, cfg} ->
        cfg

      :error ->
        Config.resolve("claude_code", Keyword.take(opts, [:user_uuid, :workspace_id]))
    end
  end

  defp settings_file_for_role(role) when is_binary(role) and role != "" do
    # Repo root is 4 levels up from runtime/lib/esr/plugins/claude_code/.
    repo_root =
      :code.priv_dir(:esr)
      |> Path.join("../../..")
      |> Path.expand()

    path = Path.join([repo_root, "roles", role, "settings.json"])

    if File.exists?(path), do: {:ok, path}, else: :error
  end

  defp settings_file_for_role(_), do: :error
end
