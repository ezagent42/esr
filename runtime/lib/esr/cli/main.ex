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

      ["exec", slash_text | _] ->
        cmd_exec(slash_text)

      ["exec"] ->
        IO.puts(:stderr, "esr exec: missing slash text. usage: esr exec /<slash>")
        System.halt(2)

      ["--version"] ->
        IO.puts("esr 0.1.0 (PR-2.5 escript skeleton)")

      [unknown | _] ->
        IO.puts(:stderr, "esr: unknown command #{inspect(unknown)}")
        print_help()
        System.halt(2)
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

  defp cmd_exec(slash_text) do
    # Per-Phase 2 spec: the queue-file transport is the v1 path.
    # Write to admin_queue/pending/<id>.yaml; poll completed/<id>.yaml.
    home = System.get_env("ESRD_HOME") || Path.join(System.user_home!(), ".esrd-dev")
    instance = System.get_env("ESR_INSTANCE") || "default"
    queue_dir = Path.join([home, instance, "admin_queue"])
    pending_dir = Path.join(queue_dir, "pending")
    completed_dir = Path.join(queue_dir, "completed")
    failed_dir = Path.join(queue_dir, "failed")

    File.mkdir_p!(pending_dir)

    id = ulid()
    pending_path = Path.join(pending_dir, "#{id}.yaml")

    {kind, args} = parse_slash(slash_text)

    submitted_by = System.get_env("ESR_OPERATOR_PRINCIPAL_ID") || "ou_unknown"

    yaml = """
    id: #{id}
    kind: #{kind}
    submitted_by: #{submitted_by}
    args:
    #{format_args_yaml(args)}
    """

    # Atomic write: tmp + rename so the Watcher's filter rule (skips
    # `.tmp`) doesn't fire on partial content.
    tmp = pending_path <> ".tmp"
    File.write!(tmp, yaml)
    File.rename!(tmp, pending_path)

    case poll_for_result(id, completed_dir, failed_dir, 60_000) do
      {:ok, dir, doc} ->
        result = doc["result"] || %{}
        text = render_result(result)
        IO.puts(text)
        if dir == "failed", do: System.halt(1)

      :timeout ->
        IO.puts(:stderr, "esr exec: timed out after 60s waiting for #{id}")
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

  defp render_result(result) when is_map(result) do
    cond do
      result["ok"] == true and is_binary(result["text"]) ->
        result["text"]

      result["ok"] == true ->
        "ok: " <> Jason.encode!(result)

      result["ok"] == false and is_binary(result["error"]) ->
        "error: " <> result["error"]

      result["ok"] == false and is_binary(result["type"]) ->
        "error: " <> result["type"]

      true ->
        Jason.encode!(result)
    end
  end

  defp render_result(other), do: inspect(other)

  # Parse "/foo arg=val arg2=val2" → {"foo", %{"arg" => "val", ...}}.
  # Stripped down version of SlashHandler's parser — escript can't
  # call into the real registry, so we just split on whitespace
  # and `=`. Quoted strings not supported; if the user needs them
  # they should fall back to writing the yaml directly.
  defp parse_slash(text) do
    trimmed = String.trim(text)

    {head, rest} =
      case String.split(trimmed, ~r/\s+/, parts: 2) do
        [h] -> {h, ""}
        [h, r] -> {h, r}
      end

    kind =
      head
      |> String.trim_leading("/")
      |> String.replace("-", "_")

    args =
      rest
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce(%{}, fn token, acc ->
        case String.split(token, "=", parts: 2) do
          [k, v] -> Map.put(acc, k, v)
          _ -> acc
        end
      end)

    {kind, args}
  end

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

  defp print_help do
    IO.puts("""
    esr — Elixir-native CLI for esrd (Phase 2)

    USAGE:
      esr help [kind]              show slash route help
      esr describe-slashes [--json] [--include-internal]
                                    dump schema (text or JSON)
      esr exec /<slash> [args...]  submit a slash command via the admin
                                    queue and print the result

    ENV:
      ESR_HOST                      esrd host:port (default 127.0.0.1:4001)
      ESRD_HOME                     esrd state root (default ~/.esrd-dev)
      ESR_INSTANCE                  instance name (default `default`)
      ESR_OPERATOR_PRINCIPAL_ID     submitted_by for exec'd commands
    """)
  end
end
