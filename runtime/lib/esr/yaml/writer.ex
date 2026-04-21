defmodule Esr.Yaml.Writer do
  @moduledoc """
  Round-trip YAML writer. Takes a map (or list), emits stable output.

  DOES NOT preserve comments. Operators should not put load-bearing
  comments in files the Admin dispatcher writes — see docs/operations/
  dev-prod-isolation.md §4.

  Scalar quoting rules (covers ULID strings, bool-looking strings, and
  YAML special chars — see plan DI-6 §Task 12 subagent-review notes):
    * empty string → `""`
    * all-digit string (e.g. ULID-like `01ARZ...` or `0123`) → quoted
    * keyword coercible to bool/null (`true`/`false`/`null`/`yes`/`no`/
      `on`/`off`) → quoted
    * contains `:`, `#`, `"`, `\\n`, or `'` → quoted + double-quotes escaped
    * starts with YAML special (`-`, `*`, `&`, `!`, `%`, `@`, `` ` ``,
      `|`, `>`) → quoted
  """

  @spec write(Path.t(), term()) :: :ok | {:error, term()}
  def write(path, data) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, text} <- encode(data),
         :ok <- File.write(path, text) do
      :ok
    end
  end

  defp encode(data) do
    # Minimal YAML emitter for maps/lists/atoms/strings/numbers/booleans.
    try do
      {:ok, emit(data, 0) <> "\n"}
    catch
      {:unsupported, term} -> {:error, {:unsupported_type, term}}
    end
  end

  defp emit(m, indent) when is_map(m) do
    m
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n", fn {k, v} ->
      key = encode_scalar(k)

      case v do
        v when is_map(v) or is_list(v) ->
          "#{pad(indent)}#{key}:\n#{emit(v, indent + 2)}"

        _ ->
          "#{pad(indent)}#{key}: #{encode_scalar(v)}"
      end
    end)
  end

  defp emit(l, indent) when is_list(l) do
    Enum.map_join(l, "\n", fn item ->
      case item do
        item when is_map(item) or is_list(item) ->
          inner = emit(item, indent + 2) |> String.trim_leading()
          "#{pad(indent)}- #{inner}"

        _ ->
          "#{pad(indent)}- #{encode_scalar(item)}"
      end
    end)
  end

  defp emit(scalar, indent), do: "#{pad(indent)}#{encode_scalar(scalar)}"

  defp encode_scalar(nil), do: "null"
  defp encode_scalar(true), do: "true"
  defp encode_scalar(false), do: "false"
  defp encode_scalar(n) when is_number(n), do: to_string(n)

  defp encode_scalar(s) when is_binary(s) do
    cond do
      s == "" ->
        "\"\""

      # Quote strings that look like numbers (incl. ULID-ish leading zeros)
      Regex.match?(~r/^[0-9]+$/, s) ->
        "\"#{s}\""

      # Quote strings that parse as bool/null in YAML 1.1
      s in ["true", "false", "null", "yes", "no", "on", "off"] ->
        "\"#{s}\""

      # Quote strings with chars that trip the YAML parser
      String.contains?(s, [":", "#", "\"", "\n", "'"]) ->
        "\"#{String.replace(s, "\"", "\\\"")}\""

      # Quote strings that start with a YAML-significant char
      String.starts_with?(s, ["-", "*", "&", "!", "%", "@", "`", "|", ">"]) ->
        "\"#{s}\""

      true ->
        s
    end
  end

  defp encode_scalar(a) when is_atom(a), do: encode_scalar(to_string(a))
  defp encode_scalar(other), do: throw({:unsupported, other})

  defp pad(n), do: String.duplicate(" ", n)
end
