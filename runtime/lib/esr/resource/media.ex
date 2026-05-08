defmodule Esr.Resource.Media do
  @moduledoc """
  Content-addressed media storage + URI ⇄ Path resolution.

  Storage layout (per spec 2026-05-08-multimedia-content-protocol-design.md §2):

      $ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>
      $ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.refs.jsonl

  Atomicity (D3): bytes written to .tmp + rename; refs append-only via
  single-line JSON (POSIX guarantees ≤ PIPE_BUF append atomic). No
  locks. `.meta.json` is a derived cache rebuilt by future GC; not
  produced in MVP.

  Used by:
  - `Esr.Resource.Media.Inbound.handle/2` (Phase 2) for inbound writes
  - `Esr.Entity.CCProxy` (Phase 3) for outbound writes
  - `Esr.Resource.Media.PhaserRegistry.transform/2` for resolution
  """

  alias Esr.Resource.Media.LocalAddress

  @type ref_meta :: %{optional(atom() | String.t()) => term()}

  @doc """
  Resolve a resource URI to its local filesystem path.

  Returns `{:ok, Path.t()}` on success; `{:error, reason}` on failure
  where reason is one of:
  - `:invalid_uri` — URI does not parse or is not a `resources` URI
  - `:wrong_env` — URI's `<env>@` segment differs from the local env
  - `:not_found` — file does not exist at the resolved path
  """
  @spec resolve(String.t()) ::
          {:ok, Path.t()} | {:error, :invalid_uri | :wrong_env | :not_found}
  def resolve(uri) when is_binary(uri) do
    with {:ok, %{media_type: mt, sha256: sha, ext: ext, env: env_in_uri}} <-
           normalize_parse_error(Esr.Uri.parse_resource(uri)),
         :ok <- check_env(env_in_uri) do
      path = build_local_path(mt, sha, ext)

      if File.exists?(path) do
        {:ok, path}
      else
        {:error, :not_found}
      end
    end
  end

  @doc """
  Store a source file as a content-addressed resource.

  Computes SHA-256 of the source, copies to
  `$ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>`
  atomically (.tmp + rename), and appends a single line of JSON to
  `<sha256>.refs.jsonl` recording the ref metadata.

  Returns `{:ok, %{uri, sha256, path}}` on success.

  Concurrent calls with the same source bytes are safe: same SHA →
  same destination; rename collisions land bytes-identical files;
  ref appends are independent (POSIX atomic for ≤ PIPE_BUF lines).
  """
  @spec store(atom(), Path.t(), ref_meta()) ::
          {:ok, %{uri: String.t(), sha256: String.t(), path: Path.t()}}
          | {:error, :unsupported_ext | term()}
  def store(media_type, source_path, ref_meta) when is_atom(media_type) do
    ext = extension_of(source_path)

    with :ok <- validate_media_type_and_ext(media_type, ext),
         {:ok, sha} <- compute_sha256(source_path),
         target_dir = build_local_dir(media_type),
         :ok <- File.mkdir_p(target_dir) do
      dest = Path.join(target_dir, "#{sha}.#{ext}")

      with :ok <- atomic_copy(source_path, dest),
           :ok <- append_ref(target_dir, sha, ref_meta) do
        uri =
          Esr.Uri.build_resource(media_type, sha,
            ext: ext,
            env: LocalAddress.env(),
            host: LocalAddress.host_port()
          )

        {:ok, %{uri: uri, sha256: sha, path: dest}}
      end
    end
  end

  # ---- helpers ----

  # Pre-validate (media_type, ext) before any disk I/O so store/3 never leaves
  # orphan files when an invalid combination is supplied by the caller.
  defp validate_media_type_and_ext(media_type, ext) do
    try do
      # build_resource raises ArgumentError on invalid ext/media_type combos.
      # Use a dummy valid sha to exercise only the (media_type, ext) check.
      _ = Esr.Uri.build_resource(media_type, String.duplicate("0", 64), ext: ext)
      :ok
    rescue
      ArgumentError -> {:error, :unsupported_ext}
    end
  end

  # Normalize any parse failure from Esr.Uri.parse_resource/1 into :invalid_uri
  # so callers only need to handle the documented resolve/1 error atoms.
  defp normalize_parse_error({:ok, _} = ok), do: ok
  defp normalize_parse_error({:error, :invalid_uri}), do: {:error, :invalid_uri}
  defp normalize_parse_error({:error, _}), do: {:error, :invalid_uri}

  defp check_env(nil), do: :ok

  defp check_env(env) do
    if env == LocalAddress.env(), do: :ok, else: {:error, :wrong_env}
  end

  defp build_local_dir(media_type) do
    Path.join([
      esrd_home(),
      LocalAddress.env(),
      "resources",
      to_string(media_type)
    ])
  end

  defp build_local_path(mt, sha, ext) do
    Path.join(build_local_dir(mt), "#{sha}.#{ext}")
  end

  defp esrd_home do
    System.get_env("ESRD_HOME", System.user_home!() |> Path.join(".esrd"))
  end

  defp compute_sha256(path) do
    case File.read(path) do
      {:ok, bytes} ->
        sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        {:ok, sha}

      err ->
        err
    end
  end

  defp extension_of(path) do
    case path |> Path.extname() |> String.downcase() |> String.trim_leading(".") do
      "" -> "bin"
      ext -> ext
    end
  end

  defp atomic_copy(src, dest) do
    if File.exists?(dest) do
      # Same content (sha-addressed) → already stored. No-op.
      :ok
    else
      tmp = "#{dest}.tmp.#{System.unique_integer([:positive])}"

      case File.copy(src, tmp) do
        {:ok, _} ->
          case File.rename(tmp, dest) do
            :ok ->
              :ok

            err ->
              File.rm(tmp)
              err
          end

        err ->
          err
      end
    end
  end

  defp append_ref(target_dir, sha, ref_meta) do
    refs_path = Path.join(target_dir, "#{sha}.refs.jsonl")

    line =
      ref_meta
      |> Map.put(:received_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!()

    File.write(refs_path, line <> "\n", [:append])
  end
end
