defmodule Esr.Commands.Render do
  @moduledoc """
  Single renderer for command grammar. Consumes `%Esr.Commands.Meta.Spec{}`
  values and produces:

    * `help_line/1` — one line for `/help` (slash + args + short description)
    * `module_help/1` — multi-line listing for `/<resource>` and `/<resource>:help`
    * `error/2` and `error/3` — structured `%{"type" => ..., "message" => ...}` maps
      with the canonical message from the spec, optionally interpolating
      `detail` keys via `%{key}` syntax.

  Phase 1 — Step 3/3 of DSL infrastructure. Phase 3 deletes every
  hand-written error literal in command modules and routes them through
  here.
  """

  alias Esr.Commands.Meta.{Spec, Arg, ErrorDecl}

  @spec help_line(Spec.t()) :: String.t()
  def help_line(%Spec{slash: :none}), do: ""

  def help_line(%Spec{slash: slash, args: args, description: desc}) do
    args_str = render_args(args)
    arg_seg = if args_str == "", do: "", else: " " <> args_str
    "  #{slash}#{arg_seg}\n                   — #{desc}"
  end

  @spec module_help([Spec.t()]) :: String.t()
  def module_help(specs) when is_list(specs) do
    specs
    |> Enum.reject(&match?(%Spec{slash: :none}, &1))
    |> Enum.sort_by(& &1.kind)
    |> Enum.map_join("\n", &help_line/1)
  end

  @spec error(Spec.t(), atom()) :: {:error, map()}
  def error(spec, code), do: error(spec, code, %{})

  @spec error(Spec.t(), atom(), map()) :: {:error, map()}
  def error(%Spec{errors: errors, kind: kind}, code, detail) when is_atom(code) do
    case Enum.find(errors, &(&1.code == code)) do
      %ErrorDecl{message: nil} ->
        {:error, %{"type" => Atom.to_string(code), "message" => generic_message(kind, code)}}

      %ErrorDecl{message: msg} ->
        {:error, %{"type" => Atom.to_string(code), "message" => interpolate(msg, detail)}}

      nil ->
        raise ArgumentError,
              "undeclared error code #{inspect(code)} for command #{inspect(kind)}; " <>
                "add `error #{inspect(code)}, \"...\"` to its command_meta block"
    end
  end

  defp render_args(args) do
    args
    |> Enum.map(fn
      %Arg{name: n, required: true} -> "#{n}=<…>"
      %Arg{name: n} -> "[#{n}=<…>]"
    end)
    |> Enum.join(" ")
  end

  defp generic_message(kind, code) do
    "command #{kind} returned #{code} (no canonical message declared)"
  end

  defp interpolate(template, detail) when is_map(detail) do
    Regex.replace(~r/%\{(\w+)\}/, template, fn _, key ->
      case Map.get(detail, safe_atom(key), :__missing__) do
        :__missing__ -> "%{#{key}}"
        value when is_binary(value) -> value
        value -> to_string_safe(value)
      end
    end)
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing__
  end

  defp to_string_safe(value) do
    if String.Chars.impl_for(value) do
      to_string(value)
    else
      inspect(value)
    end
  end
end
