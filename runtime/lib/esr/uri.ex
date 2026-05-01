defmodule Esr.Uri do
  @moduledoc """
  Parser / builder for `esr://` URIs (spec §7.5, PRD 01 F17 +
  2026-04-27 actor-topology-routing extension).

  Grammar:

      esr://[org@]host[:port]/<segment>(/<segment>)*[?params]

  Host is REQUIRED — empty host is a syntax error. The path is one
  or more `/`-separated segments. Valid first segments:

  - Legacy 2-segment forms (still emitted today): `actor`, `adapter`,
    `handler`, `command`, `interface` — each followed by a single id.
  - Path-style RESTful forms (introduced 2026-04-27): `adapters`,
    `workspaces`, `chats`, `users`, `sessions` — followed by 1+ more
    path segments forming a hierarchical resource address. Examples:

        esr://localhost/adapters/feishu/app_dev
        esr://localhost/workspaces/ws_dev/chats/oc_xxx
        esr://localhost/users/ou_xxx
        esr://localhost/sessions/sess_42

  The struct exposes `type` (first segment as atom) and `id` (last
  segment) for legacy callers; new callers should read `segments`
  (the full list) for hierarchical resources.

  Internal short strings (e.g. `cc:sess-A`) remain legal inside a
  single process; this parser exists for cross-boundary references
  (logs, cross-process addressing, remote adapter routing).
  """

  @legacy_types ~w(actor adapter handler command interface)a
  @path_style_types ~w(adapters workspaces chats users sessions)a
  @valid_types @legacy_types ++ @path_style_types

  defstruct [:org, :host, :port, :type, :id, :segments, :params]

  @type t :: %__MODULE__{
          org: String.t() | nil,
          host: String.t(),
          port: non_neg_integer() | nil,
          type: atom(),
          id: String.t(),
          segments: [String.t()],
          params: %{String.t() => String.t()}
        }

  @type error :: :bad_scheme | :empty_host | :bad_port | :bad_path | :unknown_type | :no_path

  @doc """
  Returns the legacy type set (single-id, 2-segment URIs).
  """
  @spec legacy_types() :: [atom()]
  def legacy_types, do: @legacy_types

  @doc """
  Returns the path-style RESTful type set (introduced 2026-04-27).
  """
  @spec path_style_types() :: [atom()]
  def path_style_types, do: @path_style_types

  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse("esr://" <> rest) do
    with {:ok, authority, path_and_query} <- split_authority(rest),
         {:ok, org, host, port} <- parse_authority(authority),
         {:ok, type, id, segments, params} <- parse_path_and_query(path_and_query) do
      {:ok,
       %__MODULE__{
         org: org,
         host: host,
         port: port,
         type: type,
         id: id,
         segments: segments,
         params: params
       }}
    end
  end

  def parse(_), do: {:error, :bad_scheme}

  @doc """
  Builds a 2-segment URI (legacy form): `esr://[org@]<host>/<type>/<id>`.

  `opts` accepts `:org` to emit `org@host` (PR-21b symmetry with the
  Python builder; first production user is the session URI in PR-21d).
  """
  @spec build(atom(), String.t(), String.t(), keyword()) :: String.t()
  def build(type, id, host, opts \\ []) when type in @valid_types do
    "esr://#{authority(host, opts)}/#{type}/#{id}"
  end

  @doc """
  Builds a path-style URI from a list of path segments:
  `esr://[org@]<host>/<seg1>/<seg2>/.../<segN>`.

  The first segment must be a valid path-style type (e.g. `adapters`,
  `workspaces`, `chats`, `users`, `sessions`). Use `build/3` for legacy
  2-segment forms.

  `opts` accepts `:org` to emit `org@host` (PR-21b symmetry with
  `py/src/esr/uri.py` `build_path(..., org=...)`).
  """
  @spec build_path([String.t()], String.t(), keyword()) :: String.t()
  def build_path([first | _] = segments, host, opts \\ [])
      when length(segments) >= 2 do
    if first in Enum.map(@path_style_types, &Atom.to_string/1) do
      "esr://#{authority(host, opts)}/" <> Enum.join(segments, "/")
    else
      raise ArgumentError,
            "first segment #{inspect(first)} is not a valid path-style type " <>
              "(expected one of #{inspect(@path_style_types)})"
    end
  end

  @doc """
  Renders an `esr://` URI as an HTTP URL pointing at the given Phoenix
  Endpoint. Path segments and query string are preserved verbatim;
  scheme + authority come from `endpoint.url/0`.

  Used by `/attach` slash and any future operator-facing UI that maps
  ESR resources to HTTP views — the rule is HTTP path = URI path.

      iex> Esr.Uri.to_http_url("esr://localhost/sessions/abc/attach", EsrWeb.Endpoint)
      "http://localhost:4001/sessions/abc/attach"
  """
  @spec to_http_url(String.t(), module()) :: String.t()
  def to_http_url("esr://" <> rest, endpoint) when is_atom(endpoint) do
    case String.split(rest, "/", parts: 2) do
      [_authority, path_and_query] ->
        endpoint.url() <> "/" <> path_and_query

      _ ->
        raise ArgumentError, "esr URI missing path: esr://#{rest}"
    end
  end

  def to_http_url(other, _endpoint),
    do: raise(ArgumentError, "not an esr:// URI: #{inspect(other)}")

  defp authority(host, opts) do
    case Keyword.get(opts, :org) do
      nil -> host
      "" -> host
      org when is_binary(org) -> "#{org}@#{host}"
    end
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

  @legacy_type_strs Enum.map(@legacy_types, &Atom.to_string/1)
  @valid_type_strs Enum.map(@valid_types, &Atom.to_string/1)

  defp parse_path_and_query(path_and_query) do
    {path, params} = split_query(path_and_query)
    segments = String.split(path, "/", trim: true)

    case segments do
      [] ->
        {:error, :bad_path}

      [_only] ->
        {:error, :bad_path}

      [type_str, id] when type_str in @legacy_type_strs ->
        {:ok, String.to_existing_atom(type_str), id, segments, params}

      [type_str | rest] when type_str in @valid_type_strs ->
        case rest do
          [] ->
            {:error, :bad_path}

          _ ->
            {:ok, String.to_existing_atom(type_str), List.last(rest), segments, params}
        end

      [_unknown | _] ->
        {:error, :unknown_type}
    end
  end

  defp split_query(path) do
    case String.split(path, "?", parts: 2) do
      [p] -> {p, %{}}
      [p, q] -> {p, URI.decode_query(q)}
    end
  end
end
