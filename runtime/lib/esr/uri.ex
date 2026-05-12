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
  @path_style_types ~w(adapters workspaces chats users sessions resources ptys)a
  @valid_types @legacy_types ++ @path_style_types

  @media_types ~w(image file audio)a
  @allowed_exts %{
    image: ~w(png jpg jpeg gif webp heic),
    file: ~w(bin pdf doc docx xls xlsx zip txt md csv),
    audio: ~w(opus mp3 wav m4a aac)
  }

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
  Parses a `resources`-type `esr://` URI into a typed map.

  Returns `{:ok, %{media_type, sha256, ext, env, host}}` on success,
  or `{:error, :invalid_uri}` if the URI does not conform to the
  resources grammar. Validates:

  - URI type is `:resources` with exactly 3 segments
  - media_type is one of #{inspect(@media_types)}
  - sha256 is exactly 64 lowercase hex characters
  - ext is in the per-media-type allowlist
  """
  @spec parse_resource(String.t() | t()) ::
          {:ok,
           %{
             media_type: atom(),
             sha256: String.t(),
             ext: String.t(),
             env: String.t() | nil,
             host: String.t()
           }}
          | {:error, :invalid_uri}
  def parse_resource(uri) when is_binary(uri) do
    with {:ok, parsed} <- parse(uri),
         :ok <- check_resource_shape(parsed) do
      [_, mt_str, last_seg] = parsed.segments

      case String.split(last_seg, ".", parts: 2) do
        [sha, ext] ->
          ext = String.downcase(ext)
          media_type = String.to_existing_atom(mt_str)

          cond do
            not validate_sha256(sha) -> {:error, :invalid_uri}
            not validate_ext(media_type, ext) -> {:error, :invalid_uri}
            true ->
              {:ok,
               %{
                 media_type: media_type,
                 sha256: sha,
                 ext: ext,
                 env: parsed.org,
                 host: parsed.host
               }}
          end

        _ ->
          {:error, :invalid_uri}
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_uri}
  end

  def parse_resource(%__MODULE__{type: :resources} = uri) do
    # Reconstruct the URI string from struct fields and re-parse as a resource.
    authority_str =
      case {uri.org, uri.port} do
        {nil, nil} -> uri.host
        {nil, port} -> "#{uri.host}:#{port}"
        {org, nil} -> "#{org}@#{uri.host}"
        {org, port} -> "#{org}@#{uri.host}:#{port}"
      end

    path = "/" <> Enum.join(uri.segments, "/")
    parse_resource("esr://#{authority_str}#{path}")
  end

  def parse_resource(%__MODULE__{}), do: {:error, :invalid_uri}

  @doc """
  Builds a `resources`-type `esr://` URI from media type + sha256 hash.

  Options:
  - `:ext` — file extension (default `"bin"`)
  - `:env` — org/env prefix emitted as `env@host` (default: none)
  - `:host` — host portion of the URI (default `"localhost"`)
  """
  @spec build_resource(atom(), String.t(), keyword()) :: String.t()
  def build_resource(media_type, sha256, opts \\ [])
      when is_atom(media_type) and is_binary(sha256) do
    ext = Keyword.get(opts, :ext, "bin") |> to_string() |> String.downcase()

    unless validate_sha256(sha256) do
      raise ArgumentError,
            "build_resource: sha256 must be 64 lowercase hex chars, got: #{inspect(sha256)}"
    end

    unless validate_ext(media_type, ext) do
      raise ArgumentError,
            "build_resource: ext #{inspect(ext)} not in allowlist for media_type #{inspect(media_type)}"
    end

    env = Keyword.get(opts, :env)
    host = Keyword.get(opts, :host, "localhost")
    build_path(["resources", to_string(media_type), "#{sha256}.#{ext}"], host, env: env)
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
    # :env is an alias for :org (closes the 2026-04-29 known gap in build_path)
    org = Keyword.get(opts, :org) || Keyword.get(opts, :env)

    case org do
      nil -> host
      "" -> host
      o when is_binary(o) -> "#{o}@#{host}"
    end
  end

  defp check_resource_shape(%__MODULE__{type: :resources, segments: segments})
       when length(segments) == 3,
       do: :ok

  defp check_resource_shape(_), do: {:error, :invalid_uri}

  defp validate_sha256(s) when byte_size(s) == 64, do: String.match?(s, ~r/^[0-9a-f]{64}$/)
  defp validate_sha256(_), do: false

  defp validate_ext(media_type, ext) do
    ext = String.downcase(ext)

    case Map.get(@allowed_exts, media_type) do
      nil -> false
      list -> ext in list
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

  # ───────────────────────────────────────────────────────────────
  # URI STORE FACADE (spec 2026-05-12-uri-identity-design.md)
  # ───────────────────────────────────────────────────────────────
  #
  # `Esr.Uri` serves two purposes:
  #   (1) `parse/1`, `build*/3` — pure parser/builder for esr:// grammar
  #   (2) `resolve/1`, `alias/2`, `put_entity/3`, `get_entity/1`, `delete/1`
  #       — store facade dispatching to `Esr.Uri.Store` GenServer + plugin handlers.
  #
  # `def alias/2` is legal Elixir despite `alias` being a kernel
  # directive — directives are recognized only at module-body top
  # level, not as function names.
  #
  # All canonical/alias URIs use the `esr://localhost/<kind>/...` form
  # so that `parse/1` (which requires a host) accepts them.

  @core_kinds ~w(users workspaces sessions agents)

  @spec resolve(String.t()) :: {:ok, canonical :: String.t()} | :not_found
  def resolve(uri) when is_binary(uri) do
    case Esr.Uri.Store.lookup_raw(uri) do
      {:ok, {:entity, _, _}} -> {:ok, uri}
      {:ok, {:alias, canonical}} -> {:ok, canonical}
      :not_found -> dispatch_to_plugin(uri)
    end
  end

  def resolve(_), do: :not_found

  @spec alias(canonical :: String.t(), alias_uri :: String.t()) ::
          :ok | {:error, atom()}
  def alias(canonical_uri, alias_uri)
      when is_binary(canonical_uri) and is_binary(alias_uri) do
    Esr.Uri.Store.put_alias(alias_uri, canonical_uri)
  end

  @spec put_entity(String.t(), atom(), struct()) :: :ok
  def put_entity(canonical_uri, kind, data)
      when is_binary(canonical_uri) and is_atom(kind) and is_struct(data) do
    Esr.Uri.Store.put_entity(canonical_uri, kind, data)
  end

  @spec get_entity(String.t()) :: {:ok, atom(), struct()} | :not_found
  def get_entity(uri) when is_binary(uri) do
    with {:ok, canonical} <- resolve(uri),
         {:ok, {:entity, kind, data}} <- Esr.Uri.Store.lookup_raw(canonical) do
      {:ok, kind, data}
    else
      _ -> :not_found
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(uri) when is_binary(uri) do
    Esr.Uri.Store.delete(uri)
  end

  # Dispatch a non-stored URI to a plugin handler if its (kind, prefix)
  # is registered. Used as a fallback in resolve/1.
  defp dispatch_to_plugin(uri) do
    case parse(uri) do
      {:ok, %__MODULE__{segments: [kind, plugin_seg | rest]}}
          when kind in @core_kinds and plugin_seg not in ["by-name", "by-uuid"] ->
        handlers = :persistent_term.get({__MODULE__, :plugin_handlers}, %{})

        case Map.fetch(handlers, kind <> "/" <> plugin_seg) do
          {:ok, handler_mod} ->
            case handler_mod.resolve(rest) do
              {:ok, canonical} -> {:ok, canonical}
              _ -> :not_found
            end

          :error ->
            :not_found
        end

      _ ->
        :not_found
    end
  end
end
