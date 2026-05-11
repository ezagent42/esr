defmodule Esr.Plugins.ClaudeCode.Launcher do
  @moduledoc """
  Elixir-native launcher for the Claude Code agent process.

  Replaces `scripts/esr-cc.sh` (deleted Phase 8). All env-var construction
  and pre-spawn filesystem operations are performed here in Elixir before
  PtyProcess is asked to exec the `claude` binary.

  ## Responsibilities

  | Was in `esr-cc.sh`                       | Moves to                                  |
  |------------------------------------------|-------------------------------------------|
  | `http_proxy` / `https_proxy` / `no_proxy` | `build_env/1` via plugin config          |
  | `ESR_ESRD_URL`                            | `build_env/1` via plugin config           |
  | `.mcp.json` write                         | `write_mcp_json/1`                        |
  | `mkdir -p "$cwd"`                         | `prepare_spawn/1` calls `File.mkdir_p/1`  |
  | `exec claude` binary                      | `prepare_spawn/1`'s `:cmd` argv           |

  ## PR-2 (2026-05-11 spec rev-3) — `prepare_spawn/1` is the sole entry

  Pre-PR-2 the production path went through a separate `spawn_cmd/1`
  helper which ONLY built argv and skipped `write_mcp_json/1` — so
  `.mcp.json` never got written in live spawns and claude refused to
  start. PR-2 deletes `spawn_cmd/1` outright and routes every call site
  (`PtyProcess.os_cmd/1`) through `prepare_spawn/1`, which:

    1. Validates the workspace `dir` exists / is creatable
    2. Validates the `claude` binary is on PATH
    3. Writes `.mcp.json` to the ESRD-rooted per-session path
       (`Esr.Paths.session_mcp_json/1`)
    4. Returns `{:ok, %{cmd: argv, env: env_kw}}`

  Spec: `docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md`
  rev-3 §PR-2.
  """

  alias Esr.Plugin.Config

  @default_claude_binary System.find_executable("claude") || "claude"

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
  Write the per-session `.mcp.json` at the absolute path resolved by
  `Esr.Paths.session_mcp_json/1`.

  The written file uses the HTTP transport (scheme flip from `ws://` →
  `http://` / `wss://` → `https://`) so Claude Code's MCP client can
  reach esrd's HTTP MCP endpoint.

  ## Options

    * `:session_id` — session UUID string. Required (used for path AND for
      the `mcp/<sid>` URL segment).
    * `:esrd_url`   — WebSocket URL of the ESRD host (e.g. `ws://127.0.0.1:4001`). Required.

  Returns the absolute path written on success so callers can wire it
  into the `--mcp-config` flag.
  """
  @spec write_mcp_json(keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_mcp_json(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    esrd_url   = Keyword.fetch!(opts, :esrd_url)

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

    mcp_path = Esr.Paths.session_mcp_json(session_id)

    with :ok <- File.mkdir_p(Path.dirname(mcp_path)),
         :ok <- File.write(mcp_path, content) do
      {:ok, mcp_path}
    end
  end

  @doc """
  Full pre-spawn sequence — the SOLE entry point for spawning a claude
  process (PR-2 2026-05-11):

    1. Validate workspace `dir` (must be a non-empty string; `mkdir_p`'d)
    2. Validate `claude` binary is on PATH
    3. Write per-session `.mcp.json` to the ESRD-rooted absolute path
    4. Build argv (`--permission-mode auto`,
       `--dangerously-load-development-channels`, `--mcp-config <abs>`,
       `--add-dir <dir>`, optional role `--settings`)
    5. Build env (proxy vars + ESR_ESRD_URL via plugin config + ESR_SESSION_ID)

  Accepts both keyword-list opts (legacy/test callers) and a state map
  (production caller `Esr.Entity.PtyProcess.os_cmd/1`). A state map must
  carry `:session_id` and `:dir`; optional `:workspace_role`.

  ## Required keys (keyword form)

    * `:session_id` — session UUID string. Required.
    * `:dir`        — workspace directory. Required, non-empty.

  ## Optional keys

    * `:plugin_config` — pre-resolved config map. When absent, calls
                         `Plugin.Config.resolve("claude_code", opts)`.
    * `:user_uuid`    — forwarded to `Plugin.Config.resolve/2` when
                        `:plugin_config` is not supplied. Optional.
    * `:workspace_id` — forwarded to `Plugin.Config.resolve/2` when
                        `:plugin_config` is not supplied. Optional.
    * `:role`         — workspace role for settings file lookup. Optional.
    * `:claude_binary` — override the binary path (e.g. a mock for e2e).
                         Falls back to `System.find_executable("claude")`.
  """
  @spec prepare_spawn(keyword() | map()) ::
          {:ok, %{cmd: [String.t()], env: keyword()}} | {:error, term()}
  def prepare_spawn(input) when is_map(input) do
    # Production caller: PtyProcess state map. Translate to the canonical
    # keyword form `prepare_spawn/1` works with.
    opts = [
      session_id: Map.get(input, :session_id),
      dir:        Map.get(input, :dir),
      role:       Map.get(input, :workspace_role, "dev")
    ]

    prepare_spawn(opts)
  end

  def prepare_spawn(opts) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    dir        = Keyword.get(opts, :dir)
    role       = Keyword.get(opts, :role, "dev")

    with :ok           <- validate_session_id(session_id),
         :ok           <- ensure_dir(dir),
         {:ok, binary} <- ensure_claude_binary(opts),
         config        <- resolve_plugin_config(opts),
         {:ok, mcp_path} <-
           write_mcp_json(
             session_id: session_id,
             esrd_url: config["esrd_url"] || ""
           ) do
      cmd = build_cmd(binary, dir, role, mcp_path)
      env = build_env(plugin_config: config, session_id: session_id)
      {:ok, %{cmd: cmd, env: env}}
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp validate_session_id(sid) when is_binary(sid) and sid != "", do: :ok
  defp validate_session_id(_),  do: {:error, :missing_session_id}

  defp ensure_dir(dir) when is_binary(dir) and dir != "" do
    case File.mkdir_p(dir) do
      :ok            -> :ok
      {:error, why}  -> {:error, {:bad_dir, dir, why}}
    end
  end

  defp ensure_dir(_), do: {:error, :missing_dir}

  defp ensure_claude_binary(opts) do
    explicit = Keyword.get(opts, :claude_binary)

    cond do
      is_binary(explicit) and explicit != "" ->
        {:ok, explicit}

      is_binary(@default_claude_binary) and @default_claude_binary != "" and
          @default_claude_binary != "claude" ->
        # Compile-time `System.find_executable("claude")` resolved a real path.
        {:ok, @default_claude_binary}

      true ->
        # Fall back to a runtime probe so tests that PATH-mangle the binary
        # in `setup` (post-compile) still find it. Returns nil when truly
        # absent — surface as a structured error per PR-2.
        case System.find_executable("claude") do
          nil  -> {:error, :missing_claude_binary}
          path -> {:ok, path}
        end
    end
  end

  defp build_cmd(binary, dir, role, mcp_path) do
    flags = [
      "--permission-mode", "auto",
      "--dangerously-load-development-channels", "server:esr-channel",
      "--mcp-config", mcp_path
    ]

    flags =
      if is_binary(dir) and dir != "" do
        flags ++ ["--add-dir", dir]
      else
        flags
      end

    # Role-specific settings file (same logic as the old esr-cc.sh).
    flags =
      case settings_file_for_role(role) do
        {:ok, path} -> flags ++ ["--settings", path]
        :error      -> flags
      end

    [binary | flags]
  end

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
