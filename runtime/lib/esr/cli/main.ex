defmodule Esr.Cli.Main do
  @moduledoc """
  Phase 2 PR-2.5: Elixir-native CLI escript entry point.

  Built via `mix escript.build` from `runtime/`. Produces a
  self-contained `esr` binary that talks to a running esrd via
  the schema dump endpoint (PR-2.1) and the admin queue files.

  ## Commands shipped in PR-2.5

    * `esr help [kind]`          — pretty-print the slash schema.
    * `esr describe-slashes [--json]` — dump schema as JSON or text.
    * `esr exec /<slash>`        — submit a slash command via the
      admin queue and print the result.

  ## Endpoint resolution

  Reads `ESR_HOST` env var (default `127.0.0.1:4001`) for the schema
  dump fetch. Tests can point this at a non-default port.

  ## What's deferred to PR-2.6 / PR-2.8

    * `esr daemon {start,stop,status,restart,doctor}` — launchctl
      lifecycle (PR-2.6).
    * `esr` (no args) → REPL — interactive shell (PR-2.8).
    * `esr admin submit <kind> ...` alias retention — PR-2.6.
    * `esr notify ...` alias — PR-2.6.

  ## escript caveat

  The escript runs in a minimal BEAM VM with only the `:esr`
  application's modules and its dependencies' compiled .beam files
  bundled into the binary. NO live OTP application is started, so we
  can't call into Esr.Resource.SlashRoute.Registry directly — the
  CLI talks to the running esrd over HTTP.
  """

  @default_host "127.0.0.1:4001"

  def main(argv) do
    case argv do
      [] ->
        print_help()

      ["help"] ->
        cmd_help(nil)

      ["help", kind] ->
        cmd_help(kind)

      ["describe-slashes" | rest] ->
        cmd_describe_slashes(rest)

      ["exec" | rest] ->
        cmd_exec_argv(rest)

      # PR-2.6: backward-compat alias. `esr admin submit foo --bar=baz`
      # is the legacy operator habit; equivalent to `esr exec foo
      # --bar=baz`. Same code path; aliases that retain operator muscle
      # memory don't add new dispatch logic.
      ["admin", "submit" | rest] ->
        cmd_exec_argv(rest)

      # PR-2.6: convenience alias. `esr notify <to> <text>` is shorter
      # than `esr exec notify --to=<to> --text=<text>`.
      ["notify", to, text] ->
        cmd_exec_argv(["notify", "to=" <> to, "text=" <> text])

      ["notify" | _] ->
        IO.puts(:stderr, "esr notify: usage: esr notify <to> <text>")
        System.halt(2)

      ["daemon" | rest] ->
        cmd_daemon(rest)

      ["--version"] ->
        IO.puts("esr 0.1.0 (PR-2.6 escript)")

      # Phase B-2 (2026-05-05): catch-all routes through cmd_exec_argv so
      # operators can invoke any registered slash kind directly:
      # `esr cap list`, `esr user add ...`, `esr actors list`. Sub-action
      # token concatenation in `parse_admin_flags/4` produces the right
      # `<head>_<sub>` kind. Pre-Phase-B-2 this branch printed an error;
      # the explicit list above stays for the meta-commands (help,
      # describe-slashes, exec, admin, notify, daemon) so their hand-
      # written argument shapes still work.
      argv when is_list(argv) and argv != [] ->
        cmd_exec_argv(argv)
    end
  end

  # ------------------------------------------------------------------
  # help / describe-slashes — read schema dump from running esrd
  # ------------------------------------------------------------------

  defp cmd_help(kind_filter) do
    case fetch_schema(include_internal: false) do
      {:ok, schema} ->
        slashes = schema["slashes"] || []

        filtered =
          if kind_filter,
            do: Enum.filter(slashes, fn s -> s["kind"] == kind_filter end),
            else: slashes

        if filtered == [] do
          if kind_filter do
            IO.puts(:stderr, "esr help: no slash named #{inspect(kind_filter)}")
            System.halt(1)
          else
            IO.puts("(no slash routes registered)")
          end
        else
          format_help(filtered)
        end

      {:error, reason} ->
        IO.puts(:stderr, "esr help: failed to fetch schema (#{reason})")
        System.halt(1)
    end
  end

  defp cmd_describe_slashes(rest) do
    json? = "--json" in rest
    include_internal? = "--include-internal" in rest

    case fetch_schema(include_internal: include_internal?) do
      {:ok, schema} ->
        if json? do
          IO.puts(Jason.encode!(schema, pretty: true))
        else
          slashes = schema["slashes"] || []
          internal = schema["internal_kinds"] || []

          IO.puts("slashes (#{length(slashes)}):")
          format_help(slashes)

          if include_internal? and internal != [] do
            IO.puts("\ninternal_kinds (#{length(internal)}):")

            for entry <- internal do
              IO.puts("  - #{entry["kind"]}: #{entry["description"] || ""}")
            end
          end
        end

      {:error, reason} ->
        IO.puts(:stderr, "esr describe-slashes: failed (#{reason})")
        System.halt(1)
    end
  end

  defp format_help(routes) do
    routes
    |> Enum.sort_by(fn r -> {r["category"] || "其他", r["kind"]} end)
    |> Enum.each(fn r ->
      slash = r["slash"] || ("/" <> r["kind"])
      desc = r["description"] || ""
      IO.puts("  #{slash}  — #{desc}")
    end)
  end

  # ------------------------------------------------------------------
  # exec — submit a slash command via the admin queue
  # ------------------------------------------------------------------

  # Phase B-2 (2026-05-05): explicit click-style flag parser. Pre-fix
  # `cmd_exec_argv/1` joined argv into a slash-text and let `parse_slash`
  # tokenise — but `--wait` / `--timeout VAL` (escript-side wait flags
  # carried over from Python's `esr admin submit`) leaked through as
  # phantom positionals, breaking sub-action detection. The parser
  # below recognises:
  #
  #   * `--wait`                — escript already polls; consumed.
  #   * `--timeout <secs>`      — sets poll budget; consumed.
  #   * `--arg key=value`       — Python-click form, splits into args.
  #   * `--key=value`           — generic kv flag.
  #   * `key=value`             — bare kv form.
  #   * `<bare-alphanumeric>`   — sub-action; concatenated into kind
  #                               (`cap list` → kind `cap_list`).
  defp cmd_exec_argv([]) do
    IO.puts(:stderr, "esr exec: missing slash text or kind. usage: esr exec /<slash> | esr exec <kind> [--key=value...]")
    System.halt(2)
  end

  defp cmd_exec_argv([first | rest]) do
    head_kind =
      first
      |> String.trim_leading("/")
      |> String.replace("-", "_")

    {sub_actions, args, timeout_ms} = parse_admin_flags(rest, [], %{}, 60_000)

    full_kind =
      [head_kind | sub_actions]
      |> Enum.join("_")
      |> String.replace("-", "_")

    cmd_exec_kind(full_kind, args, timeout_ms)
  end

  defp parse_admin_flags([], subs, args, timeout) do
    {Enum.reverse(subs), args, timeout}
  end

  defp parse_admin_flags(["--wait" | rest], subs, args, timeout) do
    parse_admin_flags(rest, subs, args, timeout)
  end

  defp parse_admin_flags(["--timeout", t | rest], subs, args, _timeout) do
    new_timeout =
      case Integer.parse(t) do
        {n, ""} -> n * 1000
        _ -> 60_000
      end

    parse_admin_flags(rest, subs, args, new_timeout)
  end

  defp parse_admin_flags(["--arg", spec | rest], subs, args, timeout) do
    args = merge_kv(args, spec)
    parse_admin_flags(rest, subs, args, timeout)
  end

  defp parse_admin_flags(["--" <> rest_of_token | rest], subs, args, timeout) do
    args =
      case String.split(rest_of_token, "=", parts: 2) do
        [k, v] -> Map.put(args, k, v)
        _ -> args
      end

    parse_admin_flags(rest, subs, args, timeout)
  end

  defp parse_admin_flags([token | rest], subs, args, timeout) do
    cond do
      String.contains?(token, "=") ->
        parse_admin_flags(rest, subs, merge_kv(args, token), timeout)

      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_\-]*$/, token) and subs == [] ->
        parse_admin_flags(rest, [token | subs], args, timeout)

      true ->
        parse_admin_flags(rest, subs, args, timeout)
    end
  end

  defp merge_kv(args, spec) do
    case String.split(spec, "=", parts: 2) do
      [k, v] -> Map.put(args, k, v)
      _ -> args
    end
  end

  # Phase B-2 (2026-05-05): cmd_exec_kind/3 — kind + args + timeout
  # come pre-parsed from `parse_admin_flags/4`. Pre-Phase-B-2 the
  # entry point was `cmd_exec/1` taking a slash-text that the now-
  # unused `parse_slash/1` re-tokenised; merging via slash-text was
  # lossy (`--wait` / `--timeout VAL` couldn't round-trip).
  defp cmd_exec_kind(kind, args, timeout_ms)
       when is_binary(kind) and is_map(args) and is_integer(timeout_ms) do
    home = System.get_env("ESRD_HOME") || Path.join(System.user_home!(), ".esrd-dev")
    instance = System.get_env("ESR_INSTANCE") || "default"
    queue_dir = Path.join([home, instance, "admin_queue"])
    pending_dir = Path.join(queue_dir, "pending")
    completed_dir = Path.join(queue_dir, "completed")
    failed_dir = Path.join(queue_dir, "failed")

    File.mkdir_p!(pending_dir)

    id = ulid()
    pending_path = Path.join(pending_dir, "#{id}.yaml")

    submitted_by = System.get_env("ESR_OPERATOR_PRINCIPAL_ID") || "ou_unknown"

    yaml = """
    id: #{id}
    kind: #{kind}
    submitted_by: #{submitted_by}
    args:
    #{format_args_yaml(args)}
    """

    tmp = pending_path <> ".tmp"
    File.write!(tmp, yaml)
    File.rename!(tmp, pending_path)

    case poll_for_result(id, completed_dir, failed_dir, timeout_ms) do
      {:ok, dir, doc} ->
        result = doc["result"] || %{}
        text = render_result(result)
        IO.puts(text)
        if dir == "failed", do: System.halt(1)

      :timeout ->
        IO.puts(:stderr, "esr exec: timed out after #{div(timeout_ms, 1000)}s waiting for #{id}")
        System.halt(1)
    end
  end

  defp poll_for_result(id, completed_dir, failed_dir, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        File.exists?(Path.join(completed_dir, "#{id}.yaml")) ->
          {:found, "completed"}

        File.exists?(Path.join(failed_dir, "#{id}.yaml")) ->
          {:found, "failed"}

        true ->
          Process.sleep(100)
          :wait
      end
    end)
    |> Enum.reduce_while(:wait, fn
      {:found, dir}, _ ->
        path =
          case dir do
            "completed" -> Path.join(completed_dir, "#{id}.yaml")
            "failed" -> Path.join(failed_dir, "#{id}.yaml")
          end

        case YamlElixir.read_from_file(path) do
          {:ok, doc} -> {:halt, {:ok, dir, doc}}
          _ -> {:halt, :timeout}
        end

      :wait, _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: {:halt, :timeout},
          else: {:cont, :wait}
    end)
  end

  # Phase B-1 (2026-05-05): align with Python `yaml.safe_dump(result.get("result"))`
  # so dual-rail e2e assertions (`assert_contains "$OUT" "ok: true"`,
  # `awk '/^session_id:/'`, etc.) pass on both rails. Pre-Phase-B-1 escript
  # printed only `result["text"]` for ok+text cases, missing the `ok: true`
  # line that Python emitted. See docs/notes/2026-05-05-cli-dual-rail.md.
  defp render_result(result) when is_map(result) do
    # Stable key order: ok first, then text/error, then everything else
    # alphabetically. Matches the deterministic shape Python emits via
    # `yaml.safe_dump(..., sort_keys=False)` on a result dict that always
    # ships `ok` first by convention.
    head_keys = ["ok", "text", "error", "type"]
    head = Enum.flat_map(head_keys, fn k ->
      case Map.fetch(result, k) do
        {:ok, v} -> [{k, v}]
        :error -> []
      end
    end)

    tail =
      result
      |> Enum.reject(fn {k, _} -> k in head_keys end)
      |> Enum.sort_by(fn {k, _} -> k end)

    (head ++ tail)
    |> Enum.map(fn {k, v} -> "#{k}: #{render_yaml_scalar(v)}" end)
    |> Enum.join("\n")
  end

  defp render_result(other), do: inspect(other)

  # Render an Elixir value as a YAML scalar that round-trips through
  # `yaml.safe_load`. Strings that match a "plain" pattern (alphanumeric
  # + a few path-like punctuators, no leading special) are emitted bare;
  # everything else goes through Jason which produces a valid YAML
  # double-quoted scalar (JSON ⊂ YAML).
  defp render_yaml_scalar(true), do: "true"
  defp render_yaml_scalar(false), do: "false"
  defp render_yaml_scalar(nil), do: "null"
  defp render_yaml_scalar(v) when is_integer(v), do: Integer.to_string(v)
  defp render_yaml_scalar(v) when is_float(v), do: Float.to_string(v)
  defp render_yaml_scalar(v) when is_binary(v) do
    cond do
      v == "" -> "''"
      String.contains?(v, "\n") -> Jason.encode!(v)
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_\-\.\/]*$/, v) -> v
      true -> Jason.encode!(v)
    end
  end
  defp render_yaml_scalar(v), do: Jason.encode!(v)

  # Parse "/foo arg=val arg2=val2" → {"foo", %{"arg" => "val", ...}}.
  # Phase B-2 (2026-05-05): the parser now recognises a "sub-action"
  # token immediately after the slash head, mirroring Python click's
  # subgroup convention. So `esr cap list` produces kind=`cap_list`,
  # `esr plugin enable name=ghost` produces kind=`plugin_enable` +
  # args=`{name: ghost}`. The first non-`/`-prefixed positional that
  # contains no `=` is treated as a sub-action; subsequent tokens are
  # parsed as `key=value` args. This lets the escript dispatch any
  # `<head>_<sub>` slash route registered as an internal_kind without
  # the operator typing the underscore form by hand.
  defp format_args_yaml(args) when args == %{}, do: "  {}"

  defp format_args_yaml(args) do
    args
    |> Enum.map_join("\n", fn {k, v} -> "  #{k}: #{inspect(v)}" end)
  end

  # ------------------------------------------------------------------
  # Schema fetch — talks to the running esrd's PR-2.1 endpoint.
  # ------------------------------------------------------------------

  defp fetch_schema(opts) do
    host = System.get_env("ESR_HOST") || @default_host

    query =
      if Keyword.get(opts, :include_internal, false),
        do: "?include_internal=1",
        else: ""

    url = "http://#{host}/admin/slash_schema.json#{query}"

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(IO.iodata_to_binary(body)) do
          {:ok, schema} -> {:ok, schema}
          {:error, _} -> {:error, "schema not valid JSON"}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP #{status} from #{url}"}

      {:error, reason} ->
        {:error, "#{inspect(reason)} (is esrd running at #{host}?)"}
    end
  end

  # ------------------------------------------------------------------
  # ULID-ish ID for queue files. Compatible enough with the existing
  # CLI's `01ARZ...` pattern for the file watcher's basename filter.
  # ------------------------------------------------------------------

  defp ulid do
    "01" <>
      (System.system_time(:millisecond)
       |> Integer.to_string(36)
       |> String.upcase()) <>
      (:crypto.strong_rand_bytes(6)
       |> Base.encode32(padding: false)
       |> String.replace(~r/[^A-Z0-9]/, "")
       |> String.slice(0, 14))
  end

  # ------------------------------------------------------------------
  # daemon — launchctl wrapper for esrd lifecycle (PR-2.6)
  # ------------------------------------------------------------------
  #
  # Replaces the deleted Python `cli/daemon.py` (Option A audit cleanup
  # 2026-05-05). Targets the user's launchd plist, which by convention
  # is `~/Library/LaunchAgents/com.ezagent.esrd-<instance>.plist`.
  # ESR_INSTANCE picks which one (default = "dev").

  defp cmd_daemon(["start"]), do: do_daemon(:load)
  defp cmd_daemon(["stop"]), do: do_daemon(:unload)
  defp cmd_daemon(["restart"]), do: do_daemon(:restart)
  defp cmd_daemon(["status"]), do: do_daemon(:status)

  defp cmd_daemon(_other) do
    IO.puts(:stderr, "esr daemon: usage: esr daemon {start|stop|restart|status}")
    System.halt(2)
  end

  defp do_daemon(action) do
    instance = System.get_env("ESR_INSTANCE") || "dev"
    label = "com.ezagent.esrd-#{instance}"
    plist = Path.join([System.user_home!(), "Library/LaunchAgents", "#{label}.plist"])

    unless File.exists?(plist) do
      IO.puts(
        :stderr,
        "esr daemon: plist not found at #{plist}. " <>
          "Install via scripts/esrd-launchd.sh first (or set ESR_INSTANCE)."
      )

      System.halt(1)
    end

    case action do
      :load ->
        run("launchctl", ["load", "-w", plist])

      :unload ->
        run("launchctl", ["unload", plist])

      :restart ->
        # `launchctl kickstart -k` restarts a running service in place;
        # falls back to unload/load if the service isn't loaded yet.
        case run("launchctl", ["kickstart", "-k", "gui/#{:os.cmd(~c"id -u") |> List.to_string() |> String.trim()}/#{label}"], halt: false) do
          0 ->
            :ok

          _ ->
            _ = run("launchctl", ["unload", plist], halt: false)
            run("launchctl", ["load", "-w", plist])
        end

      :status ->
        case System.cmd("launchctl", ["list"], stderr_to_stdout: true) do
          {output, 0} ->
            line =
              output
              |> String.split("\n")
              |> Enum.find(fn l -> String.contains?(l, label) end)

            if line do
              IO.puts(line)
            else
              IO.puts("#{label}: not loaded")
              System.halt(1)
            end

          {output, code} ->
            IO.puts(:stderr, output)
            System.halt(code)
        end
    end
  end

  defp run(cmd, args, opts \\ []) do
    halt? = Keyword.get(opts, :halt, true)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        if output != "", do: IO.puts(output)
        0

      {output, code} ->
        if halt? do
          IO.puts(:stderr, output)
          System.halt(code)
        else
          code
        end
    end
  end

  defp print_help do
    IO.puts("""
    esr — Elixir-native CLI for esrd (Phase 2)

    USAGE:
      esr help [kind]               show slash route help
      esr describe-slashes [--json] [--include-internal]
                                    dump schema (text or JSON)
      esr exec /<slash> [args...]   submit a slash via admin queue
      esr exec <kind> [--key=value...]
                                    same, with argv→slash translation
      esr admin submit <kind>       alias for `esr exec <kind>`
      esr notify <to> <text>        alias for `esr exec notify to=<to> text=<text>`
      esr daemon {start|stop|restart|status}
                                    launchctl wrapper for esrd

    ENV:
      ESR_HOST                      esrd host:port (default 127.0.0.1:4001)
      ESRD_HOME                     esrd state root (default ~/.esrd-dev)
      ESR_INSTANCE                  instance name (default `dev` for daemon,
                                    `default` for queue path)
      ESR_OPERATOR_PRINCIPAL_ID     submitted_by for exec'd commands
    """)
  end
end
