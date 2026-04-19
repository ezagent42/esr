defmodule Esr.Uri do
  @moduledoc """
  Parser / builder for `esr://` URIs (spec §7.5, PRD 01 F17).

  Grammar:

      esr://[org@]host[:port]/<type>/<id>[?params]

  Host is REQUIRED — empty host is a syntax error. Valid types:
  `actor`, `adapter`, `handler`, `command`, `interface`. Query string,
  when present, is decoded into a string map.

  Internal short strings (e.g. `cc:sess-A`) remain legal inside a
  single process; this parser exists for cross-boundary references
  (logs, cross-process addressing, remote adapter routing).
  """

  @valid_types ~w(actor adapter handler command interface)a

  defstruct [:org, :host, :port, :type, :id, :params]

  @type t :: %__MODULE__{
          org: String.t() | nil,
          host: String.t(),
          port: non_neg_integer() | nil,
          type: atom(),
          id: String.t(),
          params: %{String.t() => String.t()}
        }

  @type error :: :bad_scheme | :empty_host | :bad_port | :bad_path | :unknown_type | :no_path

  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse("esr://" <> rest) do
    with {:ok, authority, path_and_query} <- split_authority(rest),
         {:ok, org, host, port} <- parse_authority(authority),
         {:ok, type, id, params} <- parse_path_and_query(path_and_query) do
      {:ok,
       %__MODULE__{
         org: org,
         host: host,
         port: port,
         type: type,
         id: id,
         params: params
       }}
    end
  end

  def parse(_), do: {:error, :bad_scheme}

  @spec build(atom(), String.t(), String.t()) :: String.t()
  def build(type, id, host) when type in @valid_types do
    "esr://#{host}/#{type}/#{id}"
  end

  # ------------------------------------------------------------------
  # internals
  # ------------------------------------------------------------------

  defp split_authority(rest) do
    case String.split(rest, "/", parts: 2) do
      [authority, path_and_query] -> {:ok, authority, "/" <> path_and_query}
      _ -> {:error, :no_path}
    end
  end

  defp parse_authority(""), do: {:error, :empty_host}

  defp parse_authority(authority) do
    {org, host_port} =
      case String.split(authority, "@", parts: 2) do
        [h] -> {nil, h}
        [o, h] -> {o, h}
      end

    case String.split(host_port, ":", parts: 2) do
      [""] ->
        {:error, :empty_host}

      [host] ->
        {:ok, org, host, nil}

      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} -> {:ok, org, host, port}
          _ -> {:error, :bad_port}
        end
    end
  end

  defp parse_path_and_query(path_and_query) do
    {path, params} = split_query(path_and_query)

    case String.split(path, "/", trim: true) do
      [type_str, id] ->
        if type_str in Enum.map(@valid_types, &Atom.to_string/1) do
          {:ok, String.to_existing_atom(type_str), id, params}
        else
          {:error, :unknown_type}
        end

      _ ->
        {:error, :bad_path}
    end
  end

  defp split_query(path) do
    case String.split(path, "?", parts: 2) do
      [p] -> {p, %{}}
      [p, q] -> {p, URI.decode_query(q)}
    end
  end
end
