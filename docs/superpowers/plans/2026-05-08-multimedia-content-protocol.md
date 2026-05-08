# Multimedia Content Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable ESR peers (Feishu, Claude Code) to send and receive non-text content (image, file) end-to-end via a media-type-agnostic envelope protocol.

**Architecture:** Peer-level envelope `{msg_type, content, meta}` where non-text `content` is a content-addressed `esr://<env>@<host>/resources/<media_type>/<sha256>.<ext>` URI. Resources are stored at `$ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>` with append-only `<sha256>.refs.jsonl` for ref tracking. Per-media-type **Phasers** (Elixir + Python mirror) convert URI → consumer format (`:path` / `:base64_data_url` / `:bytes` / `:inline_text`). Plugin `manifest.yaml` declares opt-in `media_types: {inbound, outbound}` for routing-layer capability gating. The existing Elixir→Python sidecar α-wire (`{chat_id, file_name, content_b64, sha256}`) is preserved on outbound; only the upstream peer envelope becomes URI-shaped.

**Tech Stack:** Elixir / Phoenix (runtime + plugin loader + MCP HTTP transport), Python via `uv` (Feishu sidecar + `lark_oapi` + adapter SDK), POSIX filesystem (atomic `<sha>.refs.jsonl` append + tmp-rename), bash (e2e scenarios).

**Spec:** `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md` (commit `9636e87`).

**Phases (each maps to one atomic-review PR; all three implemented in this session):**
- **Phase 1 (PR-1)**: Protocol scaffold — URI grammar + Resolver + Phasers + manifest media_types. ~700-800 LOC. Acceptance: all unit tests + cross-check pass; no e2e change.
- **Phase 2 (PR-2)**: Inbound MVP — Feishu image/file → cc. ~800-900 LOC (incl. mock_feishu fidelity upgrade). Acceptance: e2e scenario 20 passes.
- **Phase 3 (PR-3)**: Outbound MVP — cc `send_file` → Feishu image/file. ~200 LOC (Elixir-only per D4). Acceptance: e2e scenario 21 passes.

---

## File Structure Map

### Phase 1 — Protocol scaffold (PR-1)

| Path | New / Modify | Responsibility |
|---|---|---|
| `runtime/lib/esr/uri.ex` | Modify | Register `:resources` path-style type; add `parse_resource/1`, `build_resource/3`; extend `build_path/3` to accept `env:` keyword (closes 2026-04-29 known gap) |
| `runtime/test/esr/uri_test.exs` | Modify | Round-trip tests for resources URIs + env keyword |
| `runtime/lib/esr/resource/media.ex` | New | Top-level facade: `resolve/1`, `store/3`, `Phaser` behaviour |
| `runtime/lib/esr/resource/media/local_address.ex` | New | `host_port/0` helper reading `EsrWeb.Endpoint.config(:http)` |
| `runtime/lib/esr/resource/media/phaser.ex` | New | `@behaviour` definition: media_type/0, input_formats/0, output_formats/0, streaming?/0, transform/2 |
| `runtime/lib/esr/resource/media/image_phaser.ex` | New | image: path/base64_data_url/bytes |
| `runtime/lib/esr/resource/media/file_phaser.ex` | New | file: path/bytes/inline_text (≤100KB text-detect) |
| `runtime/lib/esr/resource/media/phaser_registry.ex` | New | `transform(uri, target)` → resolves URI, parses media_type, dispatches to Phaser |
| `runtime/lib/esr/resource/media/plugin_registry.ex` | New | ETS-backed `lookup(plugin_name) :: %{inbound: [atom], outbound: [atom]}` populated by Plugin.Loader |
| `runtime/test/esr/resource/media/media_test.exs` | New | resolve + store unit tests |
| `runtime/test/esr/resource/media/local_address_test.exs` | New | |
| `runtime/test/esr/resource/media/image_phaser_test.exs` | New | |
| `runtime/test/esr/resource/media/file_phaser_test.exs` | New | |
| `runtime/test/esr/resource/media/phaser_registry_test.exs` | New | |
| `runtime/test/esr/resource/media/plugin_registry_test.exs` | New | |
| `py/src/esr/uri.py` | Modify | Mirror Elixir grammar extension |
| `py/tests/test_uri.py` | Modify | Mirror Elixir tests |
| `py/src/esr/resource/__init__.py` | New | Package init |
| `py/src/esr/resource/media/__init__.py` | New | `resolve`, `store`, `EsrResourceError` |
| `py/src/esr/resource/media/phaser_registry.py` | New | |
| `py/src/esr/resource/media/image_phaser.py` | New | |
| `py/src/esr/resource/media/file_phaser.py` | New | |
| `py/tests/test_resource_media.py` | New | |
| `runtime/lib/esr/plugin/manifest.ex` | Modify | Parse OPTIONAL `declares.media_types` block; default empty if absent |
| `runtime/test/esr/plugin/manifest_test.exs` | Modify | New cases for media_types parsing |
| `runtime/lib/esr/plugin/loader.ex` | Modify | Hand parsed `media_types` to `Esr.Resource.Media.PluginRegistry.register/2` |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | Modify | Add `declares.media_types: {inbound: [image, file], outbound: [image, file]}` |
| `runtime/lib/esr/plugins/claude_code/manifest.yaml` | Modify | Add same block |
| `adapters/feishu/esr.toml` | Modify | Add `[media_types]` table |
| `tests/integration/test_plugin_manifest_consistency.py` | New | Cross-check manifest.yaml ↔ esr.toml |

### Phase 2 — Inbound MVP (PR-2)

| Path | New / Modify | Responsibility |
|---|---|---|
| `adapters/feishu/src/esr_feishu/parsers.py` | Modify | image/file parsers populate `args` consistently with `{msg_id, file_key, file_name, msg_type}` |
| `adapters/feishu/src/esr_feishu/adapter.py` | Modify | `_download_file` returns `{ok, result: {uri, sha256, path}}` instead of `{ok, result: {path}}` |
| `adapters/feishu/tests/test_download.py` | Modify | Update assertions for new return shape |
| `runtime/lib/esr/resource/media/inbound.ex` | New | `handle/2` orchestrator: capability check → download_file directive → store → rebuild envelope |
| `runtime/test/esr/resource/media/inbound_test.exs` | New | Happy path + capability-miss + download-failure |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | Modify | Non-text inbound branch: invoke `Esr.Resource.Media.Inbound.handle/2` |
| `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs` | Modify | Non-text inbound case |
| `runtime/lib/esr_web/mcp_controller.ex` | Modify | SSE handler emits `meta.kind` + `meta.path` for non-text envelopes via Phaser dispatch |
| `runtime/test/esr_web/mcp_controller_test.exs` | Modify | SSE attachment test |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` (capability-miss DM) | Modify | Throttled warning DM via existing CapGuard |
| `scripts/mock_feishu.py` | Modify | Fidelity upgrade: P2ImMessageReceiveV1 with `msg_type=image\|file`; serve `im/v1/messages/<msg_id>/resources/<file_key>` |
| `tests/e2e/scenarios/20_feishu_inbound_multimedia.sh` | New | E2E |
| `docs/superpowers/prds/04-adapters.md` | Modify | Rewrite §F14 / §10.1 wording |
| `docs/notes/esr-uri-grammar.md` | Modify | Add `resources` row |
| `docs/notes/multimedia-protocol.md` | New | Field-note on protocol shape, Phaser-author guide |
| `docs/notes/claude-code-channels-reference.md` | Modify | Attachment notification shape section |
| `docs/architecture.md` | Modify | Module tree + E2E coverage map |
| `README.md` | Modify | E2E scenario table |
| `docs/futures/todo.md` | Modify | Close inbound row, add audio + GC future-work rows |

### Phase 3 — Outbound MVP (PR-3)

| Path | New / Modify | Responsibility |
|---|---|---|
| `runtime/lib/esr/plugins/claude_code/cc_proxy.ex` | Modify | Outbound `send_file`: extension → media_type, store, capability check, URI envelope |
| `runtime/test/esr/plugins/claude_code/cc_proxy_test.exs` | Modify | Outbound store + envelope build |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | Modify | Outbound non-text branch: resolve URI → existing `read_file_for_send` → existing α-wire `_send_file` directive |
| `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs` | Modify | Outbound URI-shaped envelope test |
| `tests/e2e/scenarios/21_cc_outbound_multimedia.sh` | New | E2E |
| `docs/architecture.md` | Modify | E2E coverage |
| `README.md` | Modify | |

---

## Phase 1 — Protocol Scaffold (PR-1)

### Task 1.1: Esr.Uri Elixir — register `:resources` + parse_resource/build_resource

**Files:**
- Modify: `runtime/lib/esr/uri.ex`
- Modify: `runtime/test/esr/uri_test.exs`

- [ ] **Step 1: Add failing tests for resources URI round-trip**

In `runtime/test/esr/uri_test.exs`, append:

```elixir
describe "resources path-style type" do
  test "parse_resource/1 happy path" do
    uri = "esr://default@localhost/resources/image/" <> String.duplicate("a", 64) <> ".png"
    assert {:ok, parsed} = Esr.Uri.parse_resource(uri)
    assert parsed.media_type == :image
    assert parsed.sha256 == String.duplicate("a", 64)
    assert parsed.ext == "png"
    assert parsed.env == "default"
    assert parsed.host == "localhost"
  end

  test "parse_resource/1 rejects non-64-hex sha256" do
    bad = "esr://default@localhost/resources/image/notahash.png"
    assert {:error, :invalid_uri} = Esr.Uri.parse_resource(bad)
  end

  test "parse_resource/1 rejects ext not in allowlist" do
    bad = "esr://default@localhost/resources/image/" <> String.duplicate("a", 64) <> ".exe"
    assert {:error, :invalid_uri} = Esr.Uri.parse_resource(bad)
  end

  test "parse_resource/1 rejects unknown media_type" do
    bad = "esr://default@localhost/resources/video/" <> String.duplicate("a", 64) <> ".mp4"
    assert {:error, :invalid_uri} = Esr.Uri.parse_resource(bad)
  end

  test "build_resource/3 round-trips" do
    sha = String.duplicate("b", 64)
    uri = Esr.Uri.build_resource(:image, sha, ext: "jpg", env: "prod", host: "esrd-1:4001")
    assert uri == "esr://prod@esrd-1:4001/resources/image/#{sha}.jpg"
    assert {:ok, parsed} = Esr.Uri.parse_resource(uri)
    assert parsed.media_type == :image
    assert parsed.sha256 == sha
    assert parsed.ext == "jpg"
  end

  test "build_path/3 with :env keyword (closes 2026-04-29 gap)" do
    uri = Esr.Uri.build_path(["resources", "image", "abc.png"], "localhost", env: "default")
    assert uri == "esr://default@localhost/resources/image/abc.png"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
(cd runtime && mix test test/esr/uri_test.exs --only describe:"resources path-style type")
```

Expected: FAIL with `function Esr.Uri.parse_resource/1 is undefined`.

- [ ] **Step 3: Implement parse_resource/build_resource + extend build_path**

In `runtime/lib/esr/uri.ex`:

```elixir
# Modify @path_style_types
@path_style_types ~w(adapters workspaces chats users sessions resources)a

# Add ext allowlist + media_type validation
@media_types ~w(image file audio)a
@allowed_exts %{
  image: ~w(png jpg jpeg gif webp heic),
  file:  ~w(bin pdf doc docx xls xlsx zip txt md csv),
  audio: ~w(opus mp3 wav m4a aac)
}

@spec parse_resource(String.t() | t()) ::
        {:ok, %{media_type: atom(), sha256: String.t(), ext: String.t(),
                env: String.t() | nil, host: String.t()}}
        | {:error, :invalid_uri}
def parse_resource(uri) when is_binary(uri) do
  with {:ok, parsed} <- parse(uri),
       :ok <- check_resource_shape(parsed) do
    [_, mt_str, last_seg] = parsed.segments
    [sha, ext] = String.split(last_seg, ".", parts: 2)
    media_type = String.to_existing_atom(mt_str)

    cond do
      not validate_sha256(sha) -> {:error, :invalid_uri}
      not validate_ext(media_type, ext) -> {:error, :invalid_uri}
      true -> {:ok, %{media_type: media_type, sha256: sha, ext: ext,
                      env: parsed.org, host: parsed.host}}
    end
  end
rescue
  ArgumentError -> {:error, :invalid_uri}  # to_existing_atom failure
end

def parse_resource(%__MODULE__{} = uri), do: parse_resource(to_string(uri))

@spec build_resource(atom(), String.t(), keyword()) :: String.t()
def build_resource(media_type, sha256, opts \\ []) do
  ext = Keyword.get(opts, :ext, "bin")
  env = Keyword.get(opts, :env)
  host = Keyword.get(opts, :host, "localhost")
  build_path(["resources", to_string(media_type), "#{sha256}.#{ext}"],
             host, env: env)
end

# Extend build_path to accept env keyword
@spec build_path([String.t()], String.t(), keyword()) :: String.t()
def build_path(segments, host, opts \\ []) do
  env = Keyword.get(opts, :env)
  org_prefix = if env, do: "#{env}@", else: ""
  "esr://#{org_prefix}#{host}/" <> Enum.join(segments, "/")
end

defp check_resource_shape(%__MODULE__{type: :resources, segments: segments}) when length(segments) == 3, do: :ok
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
```

Note: existing `parse/1` already returns `:org` field (per `docs/notes/esr-uri-grammar.md`). If `build_path/2` exists with arity 2, this becomes `build_path/3` — keep `build_path/2` as a delegate `def build_path(segments, host), do: build_path(segments, host, [])` for backwards-compat.

- [ ] **Step 4: Run tests to verify they pass**

```bash
(cd runtime && mix test test/esr/uri_test.exs)
```

Expected: PASS, all existing tests still green.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/uri.ex runtime/test/esr/uri_test.exs
git commit -m "feat(uri): register :resources path-style + parse_resource/build_resource

Adds the URI grammar extension required by multimedia content
protocol (spec 2026-05-08 §1). build_path/3 now accepts env: keyword,
closing the 2026-04-29 known gap noted in docs/notes/esr-uri-grammar.md.

Resource URIs validate sha256 (64-hex) + ext (per-media-type allowlist)
on parse to harden against path-traversal."
```

---

### Task 1.2: esr.uri Python mirror

**Files:**
- Modify: `py/src/esr/uri.py`
- Modify: `py/tests/test_uri.py`

- [ ] **Step 1: Add failing tests in py/tests/test_uri.py**

```python
import pytest
from esr.uri import parse, build_path, parse_resource, build_resource

class TestResources:
    def test_parse_resource_happy(self):
        sha = "a" * 64
        uri = f"esr://default@localhost/resources/image/{sha}.png"
        result = parse_resource(uri)
        assert result["media_type"] == "image"
        assert result["sha256"] == sha
        assert result["ext"] == "png"
        assert result["env"] == "default"
        assert result["host"] == "localhost"

    def test_parse_resource_rejects_bad_sha(self):
        with pytest.raises(ValueError, match="invalid_uri"):
            parse_resource("esr://default@localhost/resources/image/short.png")

    def test_parse_resource_rejects_bad_ext(self):
        sha = "a" * 64
        with pytest.raises(ValueError, match="invalid_uri"):
            parse_resource(f"esr://default@localhost/resources/image/{sha}.exe")

    def test_build_resource_round_trips(self):
        sha = "b" * 64
        uri = build_resource("image", sha, ext="jpg", env="prod", host="esrd-1:4001")
        assert uri == f"esr://prod@esrd-1:4001/resources/image/{sha}.jpg"
        result = parse_resource(uri)
        assert result["media_type"] == "image"
        assert result["sha256"] == sha

    def test_build_path_with_env(self):
        uri = build_path(["resources", "image", "abc.png"], host="localhost", env="default")
        assert uri == "esr://default@localhost/resources/image/abc.png"
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
(cd py && uv run --with pytest --with pytest-asyncio pytest tests/test_uri.py::TestResources -v)
```

Expected: FAIL with `ImportError: parse_resource`.

- [ ] **Step 3: Mirror the Elixir implementation in py/src/esr/uri.py**

```python
import re

_PATH_STYLE_TYPES = ("adapters", "workspaces", "chats", "users", "sessions", "resources")

_MEDIA_TYPES = ("image", "file", "audio")

_ALLOWED_EXTS = {
    "image": ("png", "jpg", "jpeg", "gif", "webp", "heic"),
    "file":  ("bin", "pdf", "doc", "docx", "xls", "xlsx", "zip", "txt", "md", "csv"),
    "audio": ("opus", "mp3", "wav", "m4a", "aac"),
}

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def parse_resource(uri):
    parsed = parse(uri)  # existing parser
    if parsed["type"] != "resources":
        raise ValueError("invalid_uri: not a resources URI")
    if len(parsed["segments"]) != 3:
        raise ValueError("invalid_uri: bad segment count")

    _, mt_str, last_seg = parsed["segments"]
    if mt_str not in _MEDIA_TYPES:
        raise ValueError(f"invalid_uri: unknown media_type {mt_str}")

    if "." not in last_seg:
        raise ValueError("invalid_uri: missing ext")
    sha, ext = last_seg.rsplit(".", 1)

    if not _SHA256_RE.match(sha):
        raise ValueError("invalid_uri: bad sha256")
    if ext.lower() not in _ALLOWED_EXTS[mt_str]:
        raise ValueError(f"invalid_uri: ext {ext} not allowed for {mt_str}")

    return {
        "media_type": mt_str,
        "sha256": sha,
        "ext": ext.lower(),
        "env": parsed.get("org"),
        "host": parsed["host"],
    }


def build_resource(media_type, sha256, *, ext="bin", env=None, host="localhost"):
    return build_path(
        ["resources", media_type, f"{sha256}.{ext}"],
        host=host,
        env=env,
    )


# Extend build_path to accept env (already supports `org=` per the doc; align name)
def build_path(segments, *, host, env=None, org=None):
    org_arg = env or org
    org_prefix = f"{org_arg}@" if org_arg else ""
    return f"esr://{org_prefix}{host}/" + "/".join(segments)
```

- [ ] **Step 4: Run tests to verify pass**

```bash
(cd py && uv run --with pytest --with pytest-asyncio pytest tests/test_uri.py -v)
```

Expected: PASS, all existing test_uri.py tests still green.

- [ ] **Step 5: Commit**

```bash
git add py/src/esr/uri.py py/tests/test_uri.py
git commit -m "feat(esr.uri): mirror :resources path-style type + parse_resource/build_resource

Symmetry with Elixir parser (spec 2026-05-08 §1.2). build_path now
accepts env= keyword aligned with the new Elixir build_path/3 signature."
```

---

### Task 1.3: Esr.Resource.Media.LocalAddress helper

**Files:**
- Create: `runtime/lib/esr/resource/media/local_address.ex`
- Create: `runtime/test/esr/resource/media/local_address_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Esr.Resource.Media.LocalAddressTest do
  use ExUnit.Case
  alias Esr.Resource.Media.LocalAddress

  test "host_port/0 returns localhost:<phoenix_port>" do
    [host_port: hp] = [host_port: LocalAddress.host_port()]
    assert hp =~ ~r/^[a-zA-Z0-9.-]+:[0-9]+$/
  end
end
```

- [ ] **Step 2: Run test, confirm failure**

```bash
(cd runtime && mix test test/esr/resource/media/local_address_test.exs)
```

Expected: FAIL with `module Esr.Resource.Media.LocalAddress is not loaded`.

- [ ] **Step 3: Implement helper**

`runtime/lib/esr/resource/media/local_address.ex`:

```elixir
defmodule Esr.Resource.Media.LocalAddress do
  @moduledoc """
  Single-source helper exposing the bound host:port of the local
  esrd daemon. The Phoenix Endpoint's `:http` config is the SoT
  (`runtime/lib/esr/application.ex:436`); this module centralizes
  access so URI builders don't hardcode "localhost".

  Used by:
  - `Esr.Resource.Media.store/3` to build `esr://<env>@<host>/resources/...`
  - Future cross-host resource fetch (out of scope for this PR)
  """

  @spec host_port() :: String.t()
  def host_port do
    case EsrWeb.Endpoint.config(:http) do
      [_ | _] = http_opts ->
        port = Keyword.get(http_opts, :port, 4001)
        host = "localhost"  # MVP — see future work in spec for cross-host
        "#{host}:#{port}"

      _ ->
        # Fallback when Endpoint not configured (test envs)
        "localhost:4001"
    end
  end

  @spec env() :: String.t()
  def env do
    System.get_env("ESR_INSTANCE", "default")
  end
end
```

- [ ] **Step 4: Run test, confirm pass**

```bash
(cd runtime && mix test test/esr/resource/media/local_address_test.exs)
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/media/local_address.ex runtime/test/esr/resource/media/local_address_test.exs
git commit -m "feat(resource.media): LocalAddress helper for URI builder host

Centralizes EsrWeb.Endpoint.config(:http) access (per spec D5/D7
implementation note). MVP returns localhost:<port>; future PR
introduces cross-host resolution."
```

---

### Task 1.4: Esr.Resource.Media — resolve + store

**Files:**
- Create: `runtime/lib/esr/resource/media.ex`
- Create: `runtime/test/esr/resource/media/media_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule Esr.Resource.MediaTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media

  setup do
    tmp = Path.join(System.tmp_dir!(), "esr_media_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "test")
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "store/3 writes content-addressed file + appends refs.jsonl", %{tmp: tmp} do
    src = Path.join(tmp, "input.png")
    File.write!(src, "fake png bytes")
    expected_sha = :crypto.hash(:sha256, "fake png bytes") |> Base.encode16(case: :lower)

    {:ok, %{uri: uri, sha256: sha, path: stored_path}} =
      Media.store(:image, src, %{adapter: "test", chat_id: "oc_xx"})

    assert sha == expected_sha
    assert File.exists?(stored_path)
    assert stored_path =~ "/test/resources/image/#{sha}.png"
    assert uri == "esr://test@localhost:4001/resources/image/#{sha}.png"

    # refs.jsonl exists and has one entry
    refs_path = String.replace(stored_path, ".png", ".refs.jsonl")
    refs = File.read!(refs_path) |> String.split("\n", trim: true)
    assert length(refs) == 1
    assert refs |> hd |> Jason.decode!() |> Map.get("adapter") == "test"
  end

  test "store/3 second call with same bytes appends a ref but does not duplicate file", %{tmp: tmp} do
    src1 = Path.join(tmp, "a.png")
    src2 = Path.join(tmp, "b.png")
    File.write!(src1, "same content")
    File.write!(src2, "same content")

    {:ok, %{sha256: sha1}} = Media.store(:image, src1, %{adapter: "a", chat_id: "c1"})
    {:ok, %{sha256: sha2, path: p}} = Media.store(:image, src2, %{adapter: "b", chat_id: "c2"})

    assert sha1 == sha2
    refs = File.read!(String.replace(p, ".png", ".refs.jsonl")) |> String.split("\n", trim: true)
    assert length(refs) == 2
  end

  test "resolve/1 returns Path for a stored URI", %{tmp: tmp} do
    src = Path.join(tmp, "input.png")
    File.write!(src, "data")
    {:ok, %{uri: uri, path: p}} = Media.store(:image, src, %{})
    assert {:ok, ^p} = Media.resolve(uri)
  end

  test "resolve/1 returns :not_found for nonexistent sha256" do
    bogus = "esr://test@localhost:4001/resources/image/" <> String.duplicate("0", 64) <> ".png"
    assert {:error, :not_found} = Media.resolve(bogus)
  end

  test "resolve/1 returns :wrong_env for mismatched env" do
    bad = "esr://other@localhost:4001/resources/image/" <> String.duplicate("a", 64) <> ".png"
    assert {:error, :wrong_env} = Media.resolve(bad)
  end

  test "resolve/1 absent <env>@ defaults to local env (implicit)", %{tmp: _tmp} do
    # store creates a file; resolve URI without env should match local env
    src = Path.join(System.tmp_dir!(), "x_#{System.unique_integer([:positive])}.png")
    File.write!(src, "y")
    {:ok, %{sha256: sha}} = Media.store(:image, src, %{})
    no_env_uri = "esr://localhost:4001/resources/image/#{sha}.png"
    assert {:ok, _path} = Media.resolve(no_env_uri)
  end
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
(cd runtime && mix test test/esr/resource/media/media_test.exs)
```

Expected: FAIL.

- [ ] **Step 3: Implement Esr.Resource.Media**

`runtime/lib/esr/resource/media.ex`:

```elixir
defmodule Esr.Resource.Media do
  @moduledoc """
  Content-addressed media storage + URI ⇄ Path resolution.

  Storage layout (per spec 2026-05-08 §2):
      $ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>
      $ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.refs.jsonl

  Atomicity (D3): bytes written to .tmp + rename; refs append-only
  via single-line JSON (POSIX guarantees ≤PIPE_BUF append atomic).
  No locks. .meta.json is a derived cache rebuilt by future GC; not
  produced in MVP.
  """

  alias Esr.Resource.Media.LocalAddress

  @type ref_meta :: %{optional(atom() | String.t()) => term()}

  @spec resolve(String.t()) ::
          {:ok, Path.t()} | {:error, :invalid_uri | :wrong_env | :not_found}
  def resolve(uri) when is_binary(uri) do
    with {:ok, %{media_type: mt, sha256: sha, ext: ext, env: env_in_uri}} <-
           Esr.Uri.parse_resource(uri),
         :ok <- check_env(env_in_uri),
         path = build_local_path(mt, sha, ext),
         true <- File.exists?(path) do
      {:ok, path}
    else
      {:error, _} = err -> err
      false -> {:error, :not_found}
    end
  end

  @spec store(atom(), Path.t(), ref_meta()) ::
          {:ok, %{uri: String.t(), sha256: String.t(), path: Path.t()}}
          | {:error, term()}
  def store(media_type, source_path, ref_meta) when is_atom(media_type) do
    with {:ok, sha} <- compute_sha256(source_path),
         ext = extension_of(source_path),
         target_dir = build_local_dir(media_type),
         :ok <- File.mkdir_p(target_dir),
         dest = Path.join(target_dir, "#{sha}.#{ext}"),
         :ok <- atomic_copy(source_path, dest),
         :ok <- append_ref(target_dir, sha, ref_meta) do
      uri = Esr.Uri.build_resource(media_type, sha,
                                   ext: ext, env: LocalAddress.env(),
                                   host: LocalAddress.host_port())
      {:ok, %{uri: uri, sha256: sha, path: dest}}
    end
  end

  # ---- helpers ----

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
      err -> err
    end
  end

  defp extension_of(path) do
    path |> Path.extname() |> String.downcase() |> String.trim_leading(".")
    |> case do
      "" -> "bin"
      ext -> ext
    end
  end

  defp atomic_copy(src, dest) do
    tmp = dest <> ".tmp.#{System.unique_integer([:positive])}"
    case File.copy(src, tmp) do
      {:ok, _} ->
        case File.rename(tmp, dest) do
          :ok -> :ok
          err ->
            File.rm(tmp)
            err
        end
      err ->
        err
    end
  end

  defp append_ref(target_dir, sha, ref_meta) do
    refs_path = Path.join(target_dir, "#{sha}.refs.jsonl")
    line = ref_meta
           |> Map.put(:received_at, DateTime.utc_now() |> DateTime.to_iso8601())
           |> Jason.encode!()
    File.write(refs_path, line <> "\n", [:append])
  end
end
```

- [ ] **Step 4: Run tests, verify pass**

```bash
(cd runtime && mix test test/esr/resource/media/media_test.exs)
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/media.ex runtime/test/esr/resource/media/media_test.exs
git commit -m "feat(resource.media): resolve/1 + store/3 with append-only refs.jsonl

Content-addressed media storage per spec 2026-05-08 §2 + §3.2.
Atomic copy via .tmp+rename; refs append-only (POSIX atomic).
.meta.json deferred to future GC pass per D3."
```

---

### Task 1.5: Phaser behaviour + Image/File Phasers

**Files:**
- Create: `runtime/lib/esr/resource/media/phaser.ex`
- Create: `runtime/lib/esr/resource/media/image_phaser.ex`
- Create: `runtime/lib/esr/resource/media/file_phaser.ex`
- Create: `runtime/test/esr/resource/media/image_phaser_test.exs`
- Create: `runtime/test/esr/resource/media/file_phaser_test.exs`

- [ ] **Step 1: Failing tests**

`runtime/test/esr/resource/media/image_phaser_test.exs`:

```elixir
defmodule Esr.Resource.Media.ImagePhaserTest do
  use ExUnit.Case
  alias Esr.Resource.Media.ImagePhaser

  setup do
    tmp = Path.join(System.tmp_dir!(), "img_#{System.unique_integer([:positive])}.png")
    File.write!(tmp, <<137, 80, 78, 71, 13, 10, 26, 10>> <> "fake")  # PNG magic + payload
    on_exit(fn -> File.rm(tmp) end)
    {:ok, path: tmp}
  end

  test "media_type/0 == :image" do
    assert ImagePhaser.media_type() == :image
  end

  test "input_formats / output_formats / streaming?" do
    assert ImagePhaser.input_formats() == [:path]
    assert :path in ImagePhaser.output_formats()
    assert :base64_data_url in ImagePhaser.output_formats()
    assert :bytes in ImagePhaser.output_formats()
    assert ImagePhaser.streaming?() == false
  end

  test "transform :path is identity", %{path: p} do
    assert {:ok, ^p} = ImagePhaser.transform({:path, p}, :path)
  end

  test "transform :bytes returns file content", %{path: p} do
    {:ok, bytes} = ImagePhaser.transform({:path, p}, :bytes)
    assert is_binary(bytes)
    assert byte_size(bytes) > 0
  end

  test "transform :base64_data_url returns data: URI with mime", %{path: p} do
    {:ok, data_url} = ImagePhaser.transform({:path, p}, :base64_data_url)
    assert String.starts_with?(data_url, "data:image/png;base64,")
  end
end
```

`runtime/test/esr/resource/media/file_phaser_test.exs`:

```elixir
defmodule Esr.Resource.Media.FilePhaserTest do
  use ExUnit.Case
  alias Esr.Resource.Media.FilePhaser

  test "transform :inline_text returns content for small text file" do
    tmp = Path.join(System.tmp_dir!(), "small_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, "hello world")
    on_exit(fn -> File.rm(tmp) end)
    assert {:ok, "hello world"} = FilePhaser.transform({:path, tmp}, :inline_text)
  end

  test "transform :inline_text errors for >100KB file" do
    tmp = Path.join(System.tmp_dir!(), "big_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp, String.duplicate("x", 200_000))
    on_exit(fn -> File.rm(tmp) end)
    assert {:error, :too_large_for_inline} = FilePhaser.transform({:path, tmp}, :inline_text)
  end

  test "transform :path is identity" do
    assert {:ok, "/tmp/x"} = FilePhaser.transform({:path, "/tmp/x"}, :path)
  end
end
```

- [ ] **Step 2: Run, confirm fail**

```bash
(cd runtime && mix test test/esr/resource/media/image_phaser_test.exs test/esr/resource/media/file_phaser_test.exs)
```

Expected: FAIL.

- [ ] **Step 3: Implement behaviour + Phasers**

`runtime/lib/esr/resource/media/phaser.ex`:

```elixir
defmodule Esr.Resource.Media.Phaser do
  @moduledoc """
  Behaviour for per-media-type format converters. See spec 2026-05-08 §3.3.
  
  Phasers transform a {format, value} input tuple into a target format.
  Input is always {:path, Path.t()} in MVP (Resolver always yields a Path).
  Output formats vary per media type — image supports base64_data_url,
  file supports inline_text for small text, etc.
  """

  @callback media_type() :: atom()
  @callback input_formats() :: [atom()]
  @callback output_formats() :: [atom()]
  @callback streaming?() :: boolean()
  @callback transform(input :: {atom(), term()}, target :: atom()) ::
              {:ok, term()} | {:error, term()}
end
```

`runtime/lib/esr/resource/media/image_phaser.ex`:

```elixir
defmodule Esr.Resource.Media.ImagePhaser do
  @behaviour Esr.Resource.Media.Phaser

  @mime_by_ext %{
    "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
    "gif" => "image/gif", "webp" => "image/webp", "heic" => "image/heic"
  }

  @impl true
  def media_type, do: :image

  @impl true
  def input_formats, do: [:path]

  @impl true
  def output_formats, do: [:path, :bytes, :base64_data_url]

  @impl true
  def streaming?, do: false

  @impl true
  def transform({:path, p}, :path), do: {:ok, p}
  def transform({:path, p}, :bytes), do: File.read(p)
  def transform({:path, p}, :base64_data_url) do
    with {:ok, bytes} <- File.read(p) do
      ext = p |> Path.extname() |> String.downcase() |> String.trim_leading(".")
      mime = Map.get(@mime_by_ext, ext, "application/octet-stream")
      {:ok, "data:#{mime};base64,#{Base.encode64(bytes)}"}
    end
  end
  def transform(_, target), do: {:error, {:unsupported_target, target}}
end
```

`runtime/lib/esr/resource/media/file_phaser.ex`:

```elixir
defmodule Esr.Resource.Media.FilePhaser do
  @behaviour Esr.Resource.Media.Phaser

  @inline_text_max 100_000  # 100 KB

  @impl true
  def media_type, do: :file

  @impl true
  def input_formats, do: [:path]

  @impl true
  def output_formats, do: [:path, :bytes, :inline_text]

  @impl true
  def streaming?, do: false

  @impl true
  def transform({:path, p}, :path), do: {:ok, p}
  def transform({:path, p}, :bytes), do: File.read(p)
  def transform({:path, p}, :inline_text) do
    case File.stat(p) do
      {:ok, %File.Stat{size: size}} when size <= @inline_text_max ->
        File.read(p)
      {:ok, _} -> {:error, :too_large_for_inline}
      err -> err
    end
  end
  def transform(_, target), do: {:error, {:unsupported_target, target}}
end
```

- [ ] **Step 4: Run, verify pass**

```bash
(cd runtime && mix test test/esr/resource/media/image_phaser_test.exs test/esr/resource/media/file_phaser_test.exs)
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/media/phaser.ex runtime/lib/esr/resource/media/image_phaser.ex runtime/lib/esr/resource/media/file_phaser.ex runtime/test/esr/resource/media/
git commit -m "feat(resource.media): Phaser behaviour + Image/File Phasers

Per spec 2026-05-08 §3.3-3.4. ImagePhaser supports path/bytes/
base64_data_url; FilePhaser supports path/bytes/inline_text (≤100KB).
streaming?/0 reserved (returns false in MVP)."
```

---

### Task 1.6: PhaserRegistry — dispatch by URI

**Files:**
- Create: `runtime/lib/esr/resource/media/phaser_registry.ex`
- Create: `runtime/test/esr/resource/media/phaser_registry_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Esr.Resource.Media.PhaserRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media
  alias Esr.Resource.Media.PhaserRegistry

  setup do
    tmp = Path.join(System.tmp_dir!(), "preg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "test")
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "transform/2 routes image URI to ImagePhaser", %{tmp: tmp} do
    src = Path.join(tmp, "x.png")
    File.write!(src, "fake png")
    {:ok, %{uri: uri}} = Media.store(:image, src, %{})

    assert {:ok, path_out} = PhaserRegistry.transform(uri, :path)
    assert is_binary(path_out)
    assert String.ends_with?(path_out, ".png")
  end

  test "transform/2 returns error for unsupported target on Phaser" do
    bogus_uri = "esr://test@localhost:4001/resources/image/" <> String.duplicate("0", 64) <> ".png"
    # not_found from Resolver
    assert {:error, :not_found} = PhaserRegistry.transform(bogus_uri, :path)
  end
end
```

- [ ] **Step 2: Run, fail**

```bash
(cd runtime && mix test test/esr/resource/media/phaser_registry_test.exs)
```

- [ ] **Step 3: Implement**

`runtime/lib/esr/resource/media/phaser_registry.ex`:

```elixir
defmodule Esr.Resource.Media.PhaserRegistry do
  @moduledoc """
  Dispatches URI → consumer format transformation through the
  appropriate per-media-type Phaser. See spec 2026-05-08 §3.4.
  """

  @phasers %{
    image: Esr.Resource.Media.ImagePhaser,
    file:  Esr.Resource.Media.FilePhaser
    # audio added by future PR
  }

  @spec transform(String.t(), atom()) :: {:ok, term()} | {:error, term()}
  def transform(uri, target) when is_binary(uri) and is_atom(target) do
    with {:ok, %{media_type: mt}} <- Esr.Uri.parse_resource(uri),
         {:ok, path} <- Esr.Resource.Media.resolve(uri),
         phaser when not is_nil(phaser) <- Map.get(@phasers, mt) do
      phaser.transform({:path, path}, target)
    else
      nil -> {:error, :no_phaser_for_media_type}
      err -> err
    end
  end
end
```

- [ ] **Step 4: Run, pass**

```bash
(cd runtime && mix test test/esr/resource/media/phaser_registry_test.exs)
```

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/media/phaser_registry.ex runtime/test/esr/resource/media/phaser_registry_test.exs
git commit -m "feat(resource.media): PhaserRegistry dispatches by URI media_type"
```

---

### Task 1.7: PluginRegistry — capability lookup

**Files:**
- Create: `runtime/lib/esr/resource/media/plugin_registry.ex`
- Create: `runtime/test/esr/resource/media/plugin_registry_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Esr.Resource.Media.PluginRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media.PluginRegistry

  setup do
    {:ok, _pid} = start_supervised(PluginRegistry)
    :ok
  end

  test "register/2 stores inbound/outbound; lookup/1 returns them" do
    PluginRegistry.register("feishu", %{inbound: [:image, :file], outbound: [:image, :file]})
    assert {:ok, %{inbound: [:image, :file], outbound: [:image, :file]}} =
             PluginRegistry.lookup("feishu")
  end

  test "lookup/1 returns :not_registered for unknown plugin" do
    assert {:error, :not_registered} = PluginRegistry.lookup("nonexistent")
  end

  test "supports?/3 returns true/false based on registered direction" do
    PluginRegistry.register("cc", %{inbound: [:image], outbound: []})
    assert PluginRegistry.supports?("cc", :inbound, :image) == true
    assert PluginRegistry.supports?("cc", :inbound, :audio) == false
    assert PluginRegistry.supports?("cc", :outbound, :image) == false
    assert PluginRegistry.supports?("nonexistent", :inbound, :image) == false
  end
end
```

- [ ] **Step 2: Run, fail.**

- [ ] **Step 3: Implement**

`runtime/lib/esr/resource/media/plugin_registry.ex`:

```elixir
defmodule Esr.Resource.Media.PluginRegistry do
  @moduledoc """
  ETS-backed registry of plugin media_types capabilities. Populated
  by Esr.Plugin.Loader at boot/reload from each manifest.yaml's
  `declares.media_types` block (opt-in per spec D5). Routing layer
  consults `supports?/3` to decide whether to dispatch a non-text
  envelope to a downstream plugin.
  """
  use GenServer

  @table :esr_resource_media_plugin_registry

  @type direction :: :inbound | :outbound

  # Public API

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec register(String.t(), %{inbound: [atom()], outbound: [atom()]}) :: :ok
  def register(plugin_name, %{inbound: _, outbound: _} = caps) do
    GenServer.call(__MODULE__, {:register, plugin_name, caps})
  end

  @spec lookup(String.t()) :: {:ok, %{inbound: [atom()], outbound: [atom()]}} | {:error, :not_registered}
  def lookup(plugin_name) do
    case :ets.lookup(@table, plugin_name) do
      [{^plugin_name, caps}] -> {:ok, caps}
      [] -> {:error, :not_registered}
    end
  end

  @spec supports?(String.t(), direction(), atom()) :: boolean()
  def supports?(plugin_name, direction, media_type) when direction in [:inbound, :outbound] do
    case lookup(plugin_name) do
      {:ok, caps} -> media_type in Map.fetch!(caps, direction)
      {:error, :not_registered} -> false
    end
  end

  # Server

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, caps}, _from, state) do
    :ets.insert(@table, {name, caps})
    {:reply, :ok, state}
  end
end
```

- [ ] **Step 4: Add to supervision tree**

In `runtime/lib/esr/application.ex`, add `Esr.Resource.Media.PluginRegistry` to the children list. Find the existing `children = [...]` block (typically in `start/2`) and append:

```elixir
Esr.Resource.Media.PluginRegistry,
```

- [ ] **Step 5: Run, pass**

```bash
(cd runtime && mix test test/esr/resource/media/plugin_registry_test.exs)
```

Also smoke-test boot:

```bash
(cd runtime && mix compile && iex -S mix run -e ":timer.sleep(500); IO.inspect(Esr.Resource.Media.PluginRegistry.lookup(\"any\"))")
```

Expected: `{:error, :not_registered}`, no boot crash.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/resource/media/plugin_registry.ex runtime/test/esr/resource/media/plugin_registry_test.exs runtime/lib/esr/application.ex
git commit -m "feat(resource.media): PluginRegistry ETS-backed capability lookup

Stores per-plugin media_types declarations for routing-layer gating.
Populated by Plugin.Loader at boot (next task)."
```

---

### Task 1.8: Python `esr.resource.media` mirror

**Files:**
- Create: `py/src/esr/resource/__init__.py`
- Create: `py/src/esr/resource/media/__init__.py`
- Create: `py/src/esr/resource/media/phaser_registry.py`
- Create: `py/src/esr/resource/media/image_phaser.py`
- Create: `py/src/esr/resource/media/file_phaser.py`
- Create: `py/tests/test_resource_media.py`

- [ ] **Step 1: Failing test**

`py/tests/test_resource_media.py`:

```python
import pytest
import os
import hashlib
from pathlib import Path
from esr.resource.media import resolve, store, EsrResourceError
from esr.resource.media.phaser_registry import transform


@pytest.fixture
def tmp_esrd(tmp_path, monkeypatch):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    return tmp_path


def test_store_writes_content_addressed_and_appends_refs(tmp_esrd):
    src = tmp_esrd / "input.png"
    src.write_bytes(b"fake png bytes")
    expected_sha = hashlib.sha256(b"fake png bytes").hexdigest()

    result = store("image", str(src), {"adapter": "test", "chat_id": "oc_xx"})

    assert result["sha256"] == expected_sha
    stored = Path(result["path"])
    assert stored.exists()
    assert f"/test/resources/image/{expected_sha}.png" in str(stored)

    refs = stored.parent / f"{expected_sha}.refs.jsonl"
    assert refs.exists()
    lines = refs.read_text().strip().split("\n")
    assert len(lines) == 1


def test_store_dedups_same_bytes(tmp_esrd):
    a = tmp_esrd / "a.png"
    b = tmp_esrd / "b.png"
    a.write_bytes(b"same")
    b.write_bytes(b"same")
    r1 = store("image", str(a), {"chat": "1"})
    r2 = store("image", str(b), {"chat": "2"})
    assert r1["sha256"] == r2["sha256"]
    refs = Path(r2["path"]).parent / f"{r2['sha256']}.refs.jsonl"
    assert len(refs.read_text().strip().split("\n")) == 2


def test_resolve_round_trip(tmp_esrd):
    src = tmp_esrd / "x.png"
    src.write_bytes(b"data")
    result = store("image", str(src), {})
    p = resolve(result["uri"])
    assert str(p) == result["path"]


def test_resolve_not_found_raises(tmp_esrd):
    bogus = "esr://test@localhost:4001/resources/image/" + ("0" * 64) + ".png"
    with pytest.raises(EsrResourceError, match="not_found"):
        resolve(bogus)


def test_resolve_wrong_env_raises(tmp_esrd):
    bad = "esr://other@localhost:4001/resources/image/" + ("a" * 64) + ".png"
    with pytest.raises(EsrResourceError, match="wrong_env"):
        resolve(bad)


def test_phaser_registry_path(tmp_esrd):
    src = tmp_esrd / "x.png"
    src.write_bytes(b"\x89PNG\r\n\x1a\nfake")
    result = store("image", str(src), {})
    out = transform(result["uri"], "path")
    assert str(out).endswith(".png")


def test_phaser_registry_base64_data_url(tmp_esrd):
    src = tmp_esrd / "y.png"
    src.write_bytes(b"\x89PNG\r\n\x1a\nfake")
    result = store("image", str(src), {})
    out = transform(result["uri"], "base64_data_url")
    assert out.startswith("data:image/png;base64,")
```

- [ ] **Step 2: Run, fail**

```bash
(cd py && uv run --with pytest --with pytest-asyncio pytest tests/test_resource_media.py -v)
```

- [ ] **Step 3: Implement**

`py/src/esr/resource/__init__.py`:

```python
# Package init for esr.resource.*
```

`py/src/esr/resource/media/__init__.py`:

```python
"""
Content-addressed media storage + URI ⇄ Path resolver. Mirror of
runtime/lib/esr/resource/media.ex per spec 2026-05-08 §3.2.
"""
import hashlib
import json
import os
import pathlib
from datetime import datetime, timezone

from esr.uri import parse_resource, build_resource


class EsrResourceError(Exception):
    pass


def _esrd_home():
    return pathlib.Path(os.environ.get("ESRD_HOME", os.path.expanduser("~/.esrd")))


def _env():
    return os.environ.get("ESR_INSTANCE", "default")


def _host_port():
    # MVP: matches Esr.Resource.Media.LocalAddress fallback
    return os.environ.get("ESRD_HOST_PORT", "localhost:4001")


def _resource_dir(media_type: str) -> pathlib.Path:
    return _esrd_home() / _env() / "resources" / media_type


def resolve(uri: str) -> pathlib.Path:
    """URI → local Path. Raises EsrResourceError(invalid_uri | wrong_env | not_found)."""
    try:
        parsed = parse_resource(uri)
    except ValueError as e:
        raise EsrResourceError(f"invalid_uri: {e}") from e

    env_in = parsed.get("env")
    if env_in is not None and env_in != _env():
        raise EsrResourceError(f"wrong_env: uri claims {env_in} but local is {_env()}")

    p = _resource_dir(parsed["media_type"]) / f"{parsed['sha256']}.{parsed['ext']}"
    if not p.exists():
        raise EsrResourceError(f"not_found: {p}")
    return p


def store(media_type: str, source_path: str, ref_meta: dict) -> dict:
    """Hash, atomic-copy to resources/<media_type>/<sha>.<ext>, append refs.jsonl.
    Returns {uri, sha256, path}."""
    src = pathlib.Path(source_path)
    if not src.exists():
        raise EsrResourceError(f"source_not_found: {src}")

    h = hashlib.sha256()
    with src.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    sha = h.hexdigest()

    ext = src.suffix.lstrip(".").lower() or "bin"
    target_dir = _resource_dir(media_type)
    target_dir.mkdir(parents=True, exist_ok=True)
    dest = target_dir / f"{sha}.{ext}"

    # atomic copy via tmp + rename
    tmp = dest.with_suffix(dest.suffix + f".tmp.{os.getpid()}")
    with src.open("rb") as r, tmp.open("wb") as w:
        for chunk in iter(lambda: r.read(65536), b""):
            w.write(chunk)
    tmp.replace(dest)  # POSIX atomic on same FS

    # append ref (POSIX-atomic for ≤PIPE_BUF lines)
    ref = dict(ref_meta)
    ref["received_at"] = datetime.now(timezone.utc).isoformat()
    refs_path = target_dir / f"{sha}.refs.jsonl"
    with refs_path.open("a") as f:
        f.write(json.dumps(ref, separators=(",", ":")) + "\n")

    uri = build_resource(media_type, sha, ext=ext, env=_env(), host=_host_port())
    return {"uri": uri, "sha256": sha, "path": str(dest)}
```

`py/src/esr/resource/media/image_phaser.py`:

```python
import base64
import pathlib

_MIME = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
         "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"}


class ImagePhaser:
    media_type = "image"
    input_formats = ("path",)
    output_formats = ("path", "bytes", "base64_data_url")
    streaming = False

    @staticmethod
    def transform(input_, target):
        kind, value = input_
        if kind != "path":
            raise ValueError(f"unsupported input_format: {kind}")
        p = pathlib.Path(value)

        if target == "path":
            return p
        if target == "bytes":
            return p.read_bytes()
        if target == "base64_data_url":
            ext = p.suffix.lstrip(".").lower()
            mime = _MIME.get(ext, "application/octet-stream")
            b64 = base64.b64encode(p.read_bytes()).decode("ascii")
            return f"data:{mime};base64,{b64}"
        raise ValueError(f"unsupported_target: {target}")
```

`py/src/esr/resource/media/file_phaser.py`:

```python
import pathlib


class FilePhaser:
    media_type = "file"
    input_formats = ("path",)
    output_formats = ("path", "bytes", "inline_text")
    streaming = False

    INLINE_TEXT_MAX = 100_000

    @classmethod
    def transform(cls, input_, target):
        kind, value = input_
        if kind != "path":
            raise ValueError(f"unsupported input_format: {kind}")
        p = pathlib.Path(value)
        if target == "path":
            return p
        if target == "bytes":
            return p.read_bytes()
        if target == "inline_text":
            if p.stat().st_size > cls.INLINE_TEXT_MAX:
                raise ValueError("too_large_for_inline")
            return p.read_text()
        raise ValueError(f"unsupported_target: {target}")
```

`py/src/esr/resource/media/phaser_registry.py`:

```python
from esr.uri import parse_resource
from esr.resource.media import resolve
from esr.resource.media.image_phaser import ImagePhaser
from esr.resource.media.file_phaser import FilePhaser

_PHASERS = {
    "image": ImagePhaser,
    "file": FilePhaser,
}


def transform(uri: str, target: str):
    parsed = parse_resource(uri)
    path = resolve(uri)
    phaser = _PHASERS.get(parsed["media_type"])
    if phaser is None:
        raise ValueError(f"no_phaser_for_media_type: {parsed['media_type']}")
    return phaser.transform(("path", str(path)), target)
```

- [ ] **Step 4: Run tests, pass**

```bash
(cd py && uv run --with pytest --with pytest-asyncio pytest tests/test_resource_media.py -v)
```

- [ ] **Step 5: Commit**

```bash
git add py/src/esr/resource/ py/tests/test_resource_media.py
git commit -m "feat(esr.resource.media): Python mirror of resolve/store/Phasers

Symmetric to Elixir Esr.Resource.Media.* per spec 2026-05-08 §3.
Used by feishu sidecar for outbound resolve (Phase 3) and inbound
download_file directive (Phase 2)."
```

---

### Task 1.9: Plugin manifest parser — declares.media_types

**Files:**
- Modify: `runtime/lib/esr/plugin/manifest.ex`
- Modify: `runtime/test/esr/plugin/manifest_test.exs`
- Modify: `runtime/lib/esr/plugin/loader.ex`

- [ ] **Step 1: Read existing manifest.ex shape**

```bash
sed -n '1,80p' runtime/lib/esr/plugin/manifest.ex
```

Note the existing struct shape and `parse/1` signature.

- [ ] **Step 2: Add failing tests**

In `runtime/test/esr/plugin/manifest_test.exs`, add:

```elixir
describe "declares.media_types (opt-in per D5)" do
  test "absent block parses as empty inbound/outbound" do
    yaml = """
    name: demo
    version: 0.1.0
    declares:
      capabilities: []
    """
    {:ok, m} = Esr.Plugin.Manifest.parse_string(yaml)
    assert m.declares.media_types == %{inbound: [], outbound: []}
  end

  test "present block parses inbound/outbound atom lists" do
    yaml = """
    name: demo
    version: 0.1.0
    declares:
      media_types:
        inbound:  [image, file]
        outbound: [image]
    """
    {:ok, m} = Esr.Plugin.Manifest.parse_string(yaml)
    assert m.declares.media_types == %{inbound: [:image, :file], outbound: [:image]}
  end

  test "asymmetric (only inbound) is fine — defaults outbound []" do
    yaml = """
    name: demo
    version: 0.1.0
    declares:
      media_types:
        inbound:  [image]
    """
    {:ok, m} = Esr.Plugin.Manifest.parse_string(yaml)
    assert m.declares.media_types == %{inbound: [:image], outbound: []}
  end

  test "rejects unknown media_type with helpful error" do
    yaml = """
    name: demo
    version: 0.1.0
    declares:
      media_types:
        inbound: [video]
    """
    assert {:error, msg} = Esr.Plugin.Manifest.parse_string(yaml)
    assert msg =~ "unknown media_type"
  end
end
```

- [ ] **Step 3: Run, fail**

```bash
(cd runtime && mix test test/esr/plugin/manifest_test.exs --only describe:"declares.media_types")
```

- [ ] **Step 4: Implement**

In `runtime/lib/esr/plugin/manifest.ex`, in the `declares` parsing function, add:

```elixir
@known_media_types ~w(image file audio)a

defp parse_media_types(nil), do: {:ok, %{inbound: [], outbound: []}}
defp parse_media_types(%{} = block) do
  with {:ok, inbound} <- parse_media_list(block["inbound"] || []),
       {:ok, outbound} <- parse_media_list(block["outbound"] || []) do
    {:ok, %{inbound: inbound, outbound: outbound}}
  end
end
defp parse_media_types(_), do: {:error, "media_types must be a map"}

defp parse_media_list(list) when is_list(list) do
  result =
    Enum.reduce_while(list, [], fn s, acc ->
      atom = String.to_atom(to_string(s))
      if atom in @known_media_types do
        {:cont, [atom | acc]}
      else
        {:halt, {:error, "unknown media_type: #{s}"}}
      end
    end)

  case result do
    {:error, _} = err -> err
    list -> {:ok, Enum.reverse(list)}
  end
end
```

In the main `declares` parser, call `parse_media_types(declares["media_types"])` and put the result in `declares.media_types`.

- [ ] **Step 5: Update Plugin.Loader to register PluginRegistry entries**

In `runtime/lib/esr/plugin/loader.ex`, after a manifest is parsed and a plugin is "loaded", add a call:

```elixir
Esr.Resource.Media.PluginRegistry.register(manifest.name, manifest.declares.media_types)
```

(Find the appropriate hook — likely the `register_plugin/1` or `load/1` function — and place this call there.)

- [ ] **Step 6: Run all manifest + loader tests**

```bash
(cd runtime && mix test test/esr/plugin/)
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add runtime/lib/esr/plugin/manifest.ex runtime/test/esr/plugin/manifest_test.exs runtime/lib/esr/plugin/loader.ex
git commit -m "feat(plugin): parse OPTIONAL declares.media_types (D5)

Plugin manifests can opt into multimedia participation via
declares.media_types: {inbound: [...], outbound: [...]}. Absent
block defaults to empty lists. Loader registers parsed lists into
Esr.Resource.Media.PluginRegistry for routing-layer lookup."
```

---

### Task 1.10: Add `media_types:` to feishu + claude_code manifests

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml`

- [ ] **Step 1: Edit feishu manifest**

Add under `declares:` block in `runtime/lib/esr/plugins/feishu/manifest.yaml`:

```yaml
  media_types:
    inbound:  [image, file]
    outbound: [image, file]
```

- [ ] **Step 2: Edit claude_code manifest**

Add under `declares:` in `runtime/lib/esr/plugins/claude_code/manifest.yaml`:

```yaml
  media_types:
    inbound:  [image, file]
    outbound: [image, file]
```

- [ ] **Step 3: Smoke-boot and verify registry populated**

```bash
(cd runtime && iex -S mix run -e '
  :timer.sleep(1000)
  IO.inspect(Esr.Resource.Media.PluginRegistry.lookup("feishu"), label: "feishu")
  IO.inspect(Esr.Resource.Media.PluginRegistry.lookup("claude_code"), label: "claude_code")
')
```

Expected:
```
feishu: {:ok, %{inbound: [:image, :file], outbound: [:image, :file]}}
claude_code: {:ok, %{inbound: [:image, :file], outbound: [:image, :file]}}
```

- [ ] **Step 4: Run all plugin manifest tests**

```bash
(cd runtime && mix test test/esr/plugin/)
```

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/manifest.yaml runtime/lib/esr/plugins/claude_code/manifest.yaml
git commit -m "feat(plugins): declare media_types: image+file inbound/outbound"
```

---

### Task 1.11: adapters/feishu/esr.toml [media_types]

**Files:**
- Modify: `adapters/feishu/esr.toml`

- [ ] **Step 1: Edit**

Add after `[allowed_io]` block in `adapters/feishu/esr.toml`:

```toml
[media_types]
inbound  = ["image", "file"]
outbound = ["image", "file"]
```

- [ ] **Step 2: Verify Python side can parse it (smoke)**

```bash
(cd py && uv run --with pytest --with pytest-asyncio pytest tests/test_adapter_manifest.py -v)
```

If existing test_adapter_manifest doesn't exercise media_types, it will pass without breaking — that's fine. The cross-check test in Task 1.12 will assert the actual parse.

- [ ] **Step 3: Commit**

```bash
git add adapters/feishu/esr.toml
git commit -m "feat(adapter.feishu): declare [media_types] image+file"
```

---

### Task 1.12: Cross-check test — manifest.yaml ↔ esr.toml

**Files:**
- Create: `tests/integration/test_plugin_manifest_consistency.py`

- [ ] **Step 1: Write the test**

```python
"""
Cross-check that runtime/lib/esr/plugins/<name>/manifest.yaml's
declares.media_types matches adapters/<name>/esr.toml's [media_types].
Per spec 2026-05-08 §4.2: asymmetric presence is a CI failure;
both-absent is fine; both-present must be strictly equal.
"""
from pathlib import Path

import pytest
import tomllib  # py3.11+
import yaml


REPO = Path(__file__).resolve().parents[2]


def _plugins_with_python_adapter():
    """Return [(plugin_name, manifest_yaml_path, esr_toml_path), ...] for
    plugins that have BOTH an Elixir manifest and a Python adapter manifest."""
    plugin_dir = REPO / "runtime" / "lib" / "esr" / "plugins"
    adapter_dir = REPO / "adapters"
    pairs = []
    for p in plugin_dir.iterdir():
        if not p.is_dir():
            continue
        my = p / "manifest.yaml"
        et = adapter_dir / p.name / "esr.toml"
        if my.exists() and et.exists():
            pairs.append((p.name, my, et))
    return pairs


@pytest.mark.parametrize("name,manifest_path,toml_path", _plugins_with_python_adapter())
def test_media_types_consistency(name, manifest_path, toml_path):
    yaml_data = yaml.safe_load(manifest_path.read_text())
    yaml_mt = yaml_data.get("declares", {}).get("media_types")

    toml_data = tomllib.loads(toml_path.read_text())
    toml_mt = toml_data.get("media_types")

    if yaml_mt is None and toml_mt is None:
        # both absent — non-multimedia plugin
        return

    assert yaml_mt is not None and toml_mt is not None, (
        f"asymmetric media_types presence in plugin '{name}': "
        f"manifest.yaml={yaml_mt!r} esr.toml={toml_mt!r}"
    )

    yaml_in = sorted(yaml_mt.get("inbound", []))
    yaml_out = sorted(yaml_mt.get("outbound", []))
    toml_in = sorted(toml_mt.get("inbound", []))
    toml_out = sorted(toml_mt.get("outbound", []))

    assert yaml_in == toml_in, (
        f"plugin '{name}' inbound drift: yaml={yaml_in} vs toml={toml_in}"
    )
    assert yaml_out == toml_out, (
        f"plugin '{name}' outbound drift: yaml={yaml_out} vs toml={toml_out}"
    )
```

- [ ] **Step 2: Add tests/integration/conftest.py if missing**

```bash
mkdir -p tests/integration
touch tests/integration/__init__.py
```

- [ ] **Step 3: Run**

```bash
(cd py && uv run --with pytest --with pyyaml pytest ../tests/integration/test_plugin_manifest_consistency.py -v)
```

Expected: PASS for `feishu` plugin pair.

- [ ] **Step 4: Negative test — temporarily desync, run, confirm fail**

Quickly toggle `adapters/feishu/esr.toml` to drop one entry from inbound, re-run, confirm CI failure. Then revert.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/
git commit -m "test(integration): cross-check plugin manifest media_types consistency

Asymmetric presence between manifest.yaml and esr.toml is a CI
failure; both-absent is OK; both-present must be strictly equal."
```

---

### Phase 1 Acceptance Gate

Before moving to Phase 2, verify the entire Phase 1 surface:

- [ ] `(cd runtime && mix test)` — all green
- [ ] `(cd py && uv run --with pytest --with pytest-asyncio --with pyyaml pytest tests/ ../tests/integration/ -v)` — all green
- [ ] `(cd adapters/feishu && uv run pytest tests/ -v)` — all green
- [ ] No e2e changes; existing `tests/e2e/scenarios/01_*.sh` through `19_*.sh` unaffected

Run all together:

```bash
(cd runtime && mix test) && \
(cd py && uv run --with pytest --with pytest-asyncio --with pyyaml pytest tests/ ../tests/integration/ -v) && \
(cd adapters/feishu && uv run pytest tests/ -v)
```

Expected: full green. Tag this as the "PR-1 ready" point in your local notes; move to Phase 2.

---

## Phase 2 — Inbound MVP (PR-2)

### Task 2.1: Feishu sidecar parsers — image/file args

**Files:**
- Modify: `adapters/feishu/src/esr_feishu/parsers.py`
- Modify: `adapters/feishu/tests/test_emit_events.py`

- [ ] **Step 1: Read current parser shape**

```bash
sed -n '1,80p' adapters/feishu/src/esr_feishu/parsers.py
grep -n 'msg_type\|file_key\|image' adapters/feishu/src/esr_feishu/parsers.py | head -20
```

Note which msg_types are dispatched and what each parser yields today.

- [ ] **Step 2: Add failing test for normalized image/file args**

In `adapters/feishu/tests/test_emit_events.py`, add:

```python
def test_image_event_carries_file_key_in_args():
    raw = {
        "header": {"event_type": "im.message.receive_v1"},
        "event": {
            "message": {
                "message_id": "om_xx",
                "msg_type": "image",
                "content": '{"image_key": "img_xxx"}',
            },
            "sender": {"sender_id": {"open_id": "ou_yy"}},
        },
    }
    event = parse_message_event(raw)  # name per current parsers.py
    assert event.args["msg_type"] == "image"
    assert event.args["file_key"] == "img_xxx"
    assert event.args["msg_id"] == "om_xx"
    assert "file_name" in event.args  # may be derived; just assert present


def test_file_event_carries_file_key_and_name():
    raw = {
        "header": {"event_type": "im.message.receive_v1"},
        "event": {
            "message": {
                "message_id": "om_yy",
                "msg_type": "file",
                "content": '{"file_key": "file_xxx", "file_name": "doc.pdf"}',
            },
            "sender": {"sender_id": {"open_id": "ou_yy"}},
        },
    }
    event = parse_message_event(raw)
    assert event.args["msg_type"] == "file"
    assert event.args["file_key"] == "file_xxx"
    assert event.args["file_name"] == "doc.pdf"
```

- [ ] **Step 3: Run, fail (or pass spuriously — adjust parser to ensure full args)**

```bash
(cd adapters/feishu && uv run pytest tests/test_emit_events.py -k "image_event or file_event" -v)
```

- [ ] **Step 4: Update parsers in `adapters/feishu/src/esr_feishu/parsers.py`**

For each of `image`, `file`, `audio` parsers, ensure they yield args dict containing exactly:
- `msg_type` (str): one of "image" / "file" / "audio"
- `msg_id` (str)
- `file_key` (str): from content JSON's `image_key` (image), `file_key` (file/audio)
- `file_name` (str): from content JSON `file_name`; for image, derive from `image_key + ".png"` if absent

Implementation pattern (per parser):

```python
def parse_image_message(message):
    content = json.loads(message["content"])
    file_key = content["image_key"]
    return {
        "msg_type": "image",
        "msg_id": message["message_id"],
        "file_key": file_key,
        "file_name": content.get("file_name") or f"{file_key}.png",
    }
```

Adapt similar shape for `parse_file_message` (uses `file_key` directly) and `parse_audio_message`.

- [ ] **Step 5: Run, pass**

```bash
(cd adapters/feishu && uv run pytest tests/ -v)
```

- [ ] **Step 6: Commit**

```bash
git add adapters/feishu/src/esr_feishu/parsers.py adapters/feishu/tests/test_emit_events.py
git commit -m "feat(feishu.parsers): normalize image/file args to {msg_id, file_key, file_name, msg_type}

Spec 2026-05-08 PR-2 §4.2 row A. Required so the Elixir-side
Esr.Resource.Media.Inbound.handle/2 can call download_file directive
with consistent args across msg_types."
```

---

### Task 2.2: Feishu adapter `_download_file` returns new shape

**Files:**
- Modify: `adapters/feishu/src/esr_feishu/adapter.py:533-563`
- Modify: `adapters/feishu/tests/test_download.py`

- [ ] **Step 1: Read existing `_download_file`**

```bash
sed -n '525,575p' adapters/feishu/src/esr_feishu/adapter.py
```

Note the current `{ok, result: {path}}` return.

- [ ] **Step 2: Update test**

In `adapters/feishu/tests/test_download.py`, replace the existing assertion that checks `result["path"]` with:

```python
def test_download_file_returns_uri_sha256_path(tmp_path, monkeypatch):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")

    # Setup: stub lark client to return fixed bytes
    fake_bytes = b"\x89PNG\r\n\x1a\nfake-image-data"
    # ... (use existing test fixtures pattern; mock the lark download)

    result = adapter.handle_directive(Directive(
        action="download_file",
        args={"msg_id": "om_xx", "file_key": "img_yyy",
              "file_name": "screenshot.png", "msg_type": "image"}
    ))

    assert result["ok"] is True
    assert "uri" in result["result"]
    assert "sha256" in result["result"]
    assert "path" in result["result"]

    # URI is content-addressed
    expected_sha = hashlib.sha256(fake_bytes).hexdigest()
    assert result["result"]["sha256"] == expected_sha
    assert f"resources/image/{expected_sha}.png" in result["result"]["uri"]

    # File exists at the path
    from pathlib import Path
    assert Path(result["result"]["path"]).exists()
```

- [ ] **Step 3: Run, fail**

```bash
(cd adapters/feishu && uv run pytest tests/test_download.py -v)
```

- [ ] **Step 4: Modify `_download_file`**

In `adapters/feishu/src/esr_feishu/adapter.py:533`, rewrite the function to:

```python
def _download_file(self, args: dict[str, Any]) -> dict[str, Any]:
    """Per spec 2026-05-08 §2 + PR-2 §4.2 row B: fetch bytes from Lark,
    delegate to esr.resource.media.store/3 for content-addressing.
    Returns {ok, result: {uri, sha256, path}}."""
    msg_id = args.get("msg_id")
    file_key = args.get("file_key")
    file_name = args.get("file_name", "unknown")
    msg_type = args.get("msg_type", "file")  # "image" / "file" / "audio"

    if not msg_id or not file_key:
        return {"ok": False, "error": "missing msg_id or file_key"}

    # Fetch bytes via lark_oapi (existing logic — keep it, just write to tmp not final dest)
    import tempfile
    from esr.resource.media import store as media_store, EsrResourceError

    try:
        # Existing fetch via lark_oapi.api.im.v1.message.resource_get
        bytes_data = self._lark_resource_get(msg_id, file_key, msg_type)
    except Exception as e:
        return {"ok": False, "error": f"lark_fetch_failed: {e}"}

    # Write to a tmp file with the original ext for store/3's extension detection
    ext = pathlib.Path(file_name).suffix or self._default_ext_for(msg_type)
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tf:
        tf.write(bytes_data)
        tmp_path = tf.name

    try:
        result = media_store(
            msg_type,  # "image" / "file" / "audio" → directly maps to media_type
            tmp_path,
            {
                "adapter": "feishu",
                "instance": self._instance_id,
                "msg_id": msg_id,
                "file_key": file_key,
                "file_name": file_name,
            },
        )
    except EsrResourceError as e:
        return {"ok": False, "error": f"store_failed: {e}"}
    finally:
        os.unlink(tmp_path)

    return {"ok": True, "result": result}


def _default_ext_for(self, msg_type):
    return {"image": ".png", "file": ".bin", "audio": ".opus"}.get(msg_type, ".bin")
```

- [ ] **Step 5: Run, pass**

```bash
(cd adapters/feishu && uv run pytest tests/test_download.py -v)
```

- [ ] **Step 6: Commit**

```bash
git add adapters/feishu/src/esr_feishu/adapter.py adapters/feishu/tests/test_download.py
git commit -m "feat(feishu.adapter): _download_file returns {uri, sha256, path}

Spec 2026-05-08 PR-2 §4.2 row B. Replaces PRD §F14's
uploads/<chat_id>/<file_name> path with content-addressed
resources/<media_type>/<sha256>.<ext> via esr.resource.media.store."
```

---

### Task 2.3: Esr.Resource.Media.Inbound — handler orchestrator

**Files:**
- Create: `runtime/lib/esr/resource/media/inbound.ex`
- Create: `runtime/test/esr/resource/media/inbound_test.exs`

- [ ] **Step 1: Failing tests**

```elixir
defmodule Esr.Resource.Media.InboundTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media.Inbound

  setup do
    {:ok, _} = start_supervised(Esr.Resource.Media.PluginRegistry)
    Esr.Resource.Media.PluginRegistry.register("claude_code", %{inbound: [:image, :file], outbound: []})
    Esr.Resource.Media.PluginRegistry.register("feishu", %{inbound: [:image, :file], outbound: []})
    :ok
  end

  test "handle/2 returns {:ok, envelope} with URI on happy path" do
    # mock the directive call by passing a fake adapter callback
    fake_directive = fn _action, _args ->
      {:ok, %{
        "uri" => "esr://test@localhost:4001/resources/image/" <> String.duplicate("a", 64) <> ".png",
        "sha256" => String.duplicate("a", 64),
        "path" => "/tmp/fake.png"
      }}
    end

    inbound = %{
      msg_type: "image",
      adapter_msg: %{msg_id: "om_xx", file_key: "img_yy", file_name: "x.png", msg_type: "image"},
      meta: %{chat_id: "oc_xx", sender_id: "ou_yy", source_plugin: "feishu", target_plugin: "claude_code"}
    }

    assert {:ok, envelope} = Inbound.handle(inbound, directive_fn: fake_directive)
    assert envelope.msg_type == "image"
    assert String.starts_with?(envelope.content, "esr://")
    assert envelope.meta.chat_id == "oc_xx"
  end

  test "handle/2 returns {:error, :unsupported_kind} when target doesn't declare type" do
    Esr.Resource.Media.PluginRegistry.register("claude_code", %{inbound: [:file], outbound: []})

    inbound = %{
      msg_type: "image",
      adapter_msg: %{msg_id: "x", file_key: "y", file_name: "z.png", msg_type: "image"},
      meta: %{chat_id: "c", sender_id: "s", source_plugin: "feishu", target_plugin: "claude_code"}
    }

    assert {:error, :unsupported_kind} = Inbound.handle(inbound, directive_fn: fn _, _ -> :unreachable end)
  end

  test "handle/2 propagates directive failure" do
    fake_directive = fn _, _ -> {:ok, %{"ok" => false, "error" => "lark_fetch_failed: 404"}} end

    inbound = %{
      msg_type: "image",
      adapter_msg: %{msg_id: "x", file_key: "y", file_name: "z.png", msg_type: "image"},
      meta: %{chat_id: "c", sender_id: "s", source_plugin: "feishu", target_plugin: "claude_code"}
    }

    assert {:error, {:download_failed, "lark_fetch_failed: 404"}} =
             Inbound.handle(inbound, directive_fn: fake_directive)
  end
end
```

- [ ] **Step 2: Run, fail.**

- [ ] **Step 3: Implement**

`runtime/lib/esr/resource/media/inbound.ex`:

```elixir
defmodule Esr.Resource.Media.Inbound do
  @moduledoc """
  Orchestrates non-text inbound flow per spec 2026-05-08 §"Inbound flow":
  
    1. Capability check via PluginRegistry.supports?(target, :inbound, kind)
    2. Invoke download_file directive on source adapter (yields URI)
    3. Build envelope with URI content + meta, ready for downstream peer
  
  Caller passes directive_fn for testability + decoupling from the
  adapter_socket layer. In production the directive_fn is a closure
  that calls `Esr.Adapter.dispatch(:feishu, instance_id, action, args)`.
  """

  alias Esr.Resource.Media.PluginRegistry

  @type inbound :: %{
          msg_type: String.t(),
          adapter_msg: map(),
          meta: %{
            chat_id: String.t(),
            sender_id: String.t(),
            source_plugin: String.t(),
            target_plugin: String.t(),
            optional(atom()) => term()
          }
        }

  @spec handle(inbound(), keyword()) ::
          {:ok, %{msg_type: String.t(), content: String.t(), meta: map()}}
          | {:error, :unsupported_kind | {:download_failed, String.t()} | term()}
  def handle(inbound, opts) do
    directive_fn = Keyword.fetch!(opts, :directive_fn)
    kind = String.to_existing_atom(inbound.msg_type)
    target = inbound.meta.target_plugin
    source = inbound.meta.source_plugin

    with true <- PluginRegistry.supports?(target, :inbound, kind),
         {:ok, %{"ok" => true, "result" => %{"uri" => uri}}} <-
           directive_fn.("download_file", inbound.adapter_msg) do
      {:ok,
       %{
         msg_type: inbound.msg_type,
         content: uri,
         meta:
           inbound.meta
           |> Map.put(:source_plugin, source)
           |> Map.put(:target_plugin, target)
       }}
    else
      false -> {:error, :unsupported_kind}
      {:ok, %{"ok" => false, "error" => err}} -> {:error, {:download_failed, err}}
      err -> err
    end
  end
end
```

- [ ] **Step 4: Run, pass**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/media/inbound.ex runtime/test/esr/resource/media/inbound_test.exs
git commit -m "feat(resource.media): Inbound.handle/2 orchestrates capability check + download + envelope rebuild

Spec 2026-05-08 §Inbound flow. directive_fn passed by caller for
testability and decoupling from the adapter_socket layer."
```

---

### Task 2.4: FeishuChatProxy — non-text inbound branch + capability-miss DM

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`
- Modify: `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs`

- [ ] **Step 1: Read current handler**

```bash
grep -n 'handle_inbound\|msg_type\|text' runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex | head -20
```

Locate the function that handles inbound messages.

- [ ] **Step 2: Failing test**

```elixir
test "handle_inbound dispatches non-text via Esr.Resource.Media.Inbound" do
  # Setup PluginRegistry
  # Setup mock adapter directive function
  # Setup state
  inbound = %{"msg_type" => "image", "msg_id" => "om", "file_key" => "ik", "file_name" => "x.png",
              "chat_id" => "oc", "sender_id" => "ou"}

  # Call the proxy's inbound handler
  # Assert: forwards a URI-shaped envelope to its downstream cc proxy
  # Assert: capability check + download invoked
end

test "handle_inbound on capability-miss emits warning DM (throttled)" do
  # PluginRegistry.register("claude_code", %{inbound: [:file], outbound: []})  # no image
  # Inbound msg_type=image
  # Assert: no envelope forwarded
  # Assert: warning DM emitted with sender_id-keyed throttle
end
```

- [ ] **Step 3: Run, fail.**

- [ ] **Step 4: Implement**

In `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`, locate the inbound dispatch (the current text-only branch). Add a non-text branch that:

```elixir
defp handle_inbound(%{"msg_type" => "text"} = msg, state) do
  # existing text flow — unchanged
end

defp handle_inbound(%{"msg_type" => kind} = msg, state) when kind in ["image", "file", "audio"] do
  inbound = %{
    msg_type: kind,
    adapter_msg: %{
      "msg_id" => msg["msg_id"],
      "file_key" => msg["file_key"],
      "file_name" => msg["file_name"],
      "msg_type" => kind
    },
    meta: %{
      chat_id: msg["chat_id"],
      sender_id: msg["sender_id"],
      source_plugin: "feishu",
      target_plugin: "claude_code"
    }
  }

  directive_fn = fn action, args ->
    Esr.Plugins.Feishu.AdapterDispatch.call(state.instance_id, action, args)
  end

  case Esr.Resource.Media.Inbound.handle(inbound, directive_fn: directive_fn) do
    {:ok, envelope} ->
      # forward to downstream cc proxy as already done for text envelopes,
      # but preserving the URI-shaped content
      forward_to_cc_proxy(envelope, state)
      state

    {:error, :unsupported_kind} ->
      maybe_emit_capability_warning_dm(msg, kind, state)
      state

    {:error, reason} ->
      Logger.warning("multimedia inbound failed", reason: inspect(reason), kind: kind)
      state
  end
end
```

Add the throttled DM emitter using existing `Esr.Peers.CapGuard` or equivalent. Throttle key: `{sender_id, kind}` per D6.

```elixir
defp maybe_emit_capability_warning_dm(msg, kind, state) do
  throttle_key = "media_unsupported:#{msg["sender_id"]}:#{kind}"
  case Esr.Peers.CapGuard.try_emit(throttle_key, ttl_ms: 600_000) do
    :ok ->
      text = "操作员发了 #{kind} 类型消息，但当前 cc 不支持此类型消费 — 已忽略"
      send_dm_via_feishu(state, msg["sender_id"], text)
    :rate_limited -> :ok
  end
end
```

(If `Esr.Peers.CapGuard.try_emit/2` doesn't exist with that exact API, adapt to the actual rate-limit primitive in the codebase — find by `grep -r "deny_dm" runtime/`.)

- [ ] **Step 5: Run tests, pass**

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs
git commit -m "feat(feishu.fcp): non-text inbound via Esr.Resource.Media.Inbound

Spec 2026-05-08 PR-2 row G + capability-miss DM (D6 throttle key).
Text flow unchanged; image/file/audio inbound dispatches through
the new media protocol."
```

---

### Task 2.5: McpController SSE — attachment notification

**Files:**
- Modify: `runtime/lib/esr_web/mcp_controller.ex`
- Modify: `runtime/test/esr_web/mcp_controller_test.exs`

- [ ] **Step 1: Read existing SSE handler**

```bash
grep -n 'notifications/claude/channel\|SSE\|envelope' runtime/lib/esr_web/mcp_controller.ex | head -20
```

Find where text-only PubSub envelopes are translated to SSE frames.

- [ ] **Step 2: Failing test**

In `runtime/test/esr_web/mcp_controller_test.exs`:

```elixir
test "SSE handler emits meta.kind+meta.path for non-text envelope" do
  # Setup: subscribe a fake SSE consumer to cli:channel/<sid>
  # Setup: store a real image to resources/ via Esr.Resource.Media.store
  # Broadcast: envelope %{msg_type: "image", content: <stored uri>, meta: %{chat_id: "oc", sender_id: "ou"}}
  # Assert: SSE frame received contains data with content="[image attachment]" + meta.kind="image" + meta.path matching the stored file
end
```

- [ ] **Step 3: Run, fail.**

- [ ] **Step 4: Modify SSE handler**

Find the function that handles `:notification` PubSub messages (likely `handle_info({:notification, envelope}, ...)`). Branch on `envelope.msg_type`:

```elixir
defp build_sse_payload(%{msg_type: "text", content: text, meta: meta}) do
  # existing text path
  %{"content" => text, "meta" => stringify_keys(meta)}
end

defp build_sse_payload(%{msg_type: kind, content: uri, meta: meta}) when kind in ["image", "file", "audio"] do
  case Esr.Resource.Media.PhaserRegistry.transform(uri, :path) do
    {:ok, path} ->
      meta_with_attachment =
        meta
        |> Map.put(:kind, kind)
        |> Map.put(:path, path)
        |> stringify_keys()

      %{
        "content" => "[#{kind} attachment]",
        "meta" => meta_with_attachment
      }

    {:error, reason} ->
      Logger.warning("phaser transform failed", reason: inspect(reason), uri: uri)
      %{"content" => "[#{kind} attachment unavailable]", "meta" => stringify_keys(meta)}
  end
end

defp stringify_keys(meta) do
  meta
  |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  |> Map.new()
end
```

- [ ] **Step 5: Run tests, pass**

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr_web/mcp_controller.ex runtime/test/esr_web/mcp_controller_test.exs
git commit -m "feat(mcp_controller): SSE attachment payload via PhaserRegistry

For non-text envelopes, dispatch URI through PhaserRegistry to a
local path; emit notifications/claude/channel with content stub +
meta.kind + meta.path. Per spec §Inbound flow ⑥."
```

---

### Task 2.6: scripts/mock_feishu.py — inbound image/file fidelity

**Files:**
- Modify: `scripts/mock_feishu.py`

- [ ] **Step 1: Read current mock_feishu**

```bash
sed -n '1,80p' scripts/mock_feishu.py
grep -n 'P2ImMessageReceiveV1\|msg_type\|emit_event' scripts/mock_feishu.py | head -20
```

Note the current emit interface for inbound events.

- [ ] **Step 2: Add image/file inbound emission**

In `scripts/mock_feishu.py`, ensure `emit_message_event` accepts non-text msg_types and serves the `im/v1/messages/<msg_id>/resources/<file_key>` endpoint to return bytes for download_file.

Pseudo-code (adapt to actual mock_feishu structure):

```python
# 1. Allow caller to inject a non-text inbound:
def emit_image_inbound(self, chat_id, sender_id, image_bytes):
    msg_id = f"om_mock_{secrets.token_hex(4)}"
    file_key = f"img_mock_{secrets.token_hex(4)}"
    self._stored_resources[(msg_id, file_key)] = image_bytes
    event = {
        "header": {"event_type": "im.message.receive_v1"},
        "event": {
            "message": {
                "message_id": msg_id,
                "chat_id": chat_id,
                "msg_type": "image",
                "content": json.dumps({"image_key": file_key}),
            },
            "sender": {"sender_id": {"open_id": sender_id}},
        },
    }
    self._emit_to_subscribers(event)

# 2. Serve the download endpoint:
@app.get("/open-apis/im/v1/messages/{msg_id}/resources/{file_key}")
async def get_resource(msg_id, file_key):
    bytes_ = self._stored_resources.get((msg_id, file_key))
    if not bytes_:
        return Response(status_code=404)
    return Response(content=bytes_, media_type="application/octet-stream")
```

- [ ] **Step 3: Smoke-test mock_feishu in isolation**

```bash
python scripts/mock_feishu.py --port 9999 &
MOCK_PID=$!
# Use httpie or curl to probe a fake resource
curl http://localhost:9999/open-apis/im/v1/messages/om_xx/resources/img_yy
kill $MOCK_PID
```

- [ ] **Step 4: Commit**

```bash
git add scripts/mock_feishu.py
git commit -m "feat(mock_feishu): image+file inbound fidelity

P2ImMessageReceiveV1 emit + im/v1/messages/<msg_id>/resources/<file_key>
download endpoint. Required for e2e scenario 20.
Per docs/notes/mock-feishu-fidelity.md (image/file inbound was ❌
before this change)."
```

---

### Task 2.7: E2E scenario 20 — Feishu inbound multimedia

**Files:**
- Create: `tests/e2e/scenarios/20_feishu_inbound_multimedia.sh`

- [ ] **Step 1: Read an existing e2e scenario for shape**

```bash
cat tests/e2e/scenarios/19_session_first_default.sh
cat tests/e2e/scenarios/common.sh
```

Note the conventions: setup esrd-dev, mock_feishu, register adapter, send fixture, assert.

- [ ] **Step 2: Write scenario 20**

`tests/e2e/scenarios/20_feishu_inbound_multimedia.sh`:

```bash
#!/usr/bin/env bash
# E2E: operator sends a PNG via mock_feishu inbound, assert
# cc receives <channel> notification with kind="image" + a path
# pointing at content-addressed bytes. Per spec 2026-05-08 PR-2.
set -euo pipefail
SCENARIO_NAME="20_feishu_inbound_multimedia"
source "$(dirname "$0")/common.sh"

# 1. Boot fresh esrd-dev + mock_feishu
fresh_esrd_home
boot_esrd_dev
boot_mock_feishu
register_feishu_adapter

# 2. Bootstrap user + chat (operator)
ESRD_DEV esr user add operator
ESRD_DEV esr user bind-feishu operator ou_op
# ... etc per common.sh helpers

# 3. Place a fixture PNG and inject inbound via mock_feishu admin API
FIXTURE="$(dirname "$0")/../fixtures/screenshot.png"
[[ -f "$FIXTURE" ]] || python -c "open('$FIXTURE','wb').write(b'\\x89PNG\\r\\n\\x1a\\nfake-test-image')"

curl -s -X POST http://localhost:$MOCK_FEISHU_PORT/_admin/inject_inbound \
     -H 'Content-Type: application/json' \
     -d "$(jq -n --arg chat "$CHAT_ID" --arg sender "ou_op" \
                 --arg b64 "$(base64 < "$FIXTURE")" \
                 '{chat_id: $chat, sender_id: $sender, msg_type: "image", bytes_b64: $b64}')"

# 4. Wait for the image to be stored
ESRD_DEV bash -c 'until ls $ESRD_HOME/dev/resources/image/*.png 2>/dev/null; do sleep 0.5; done'

EXPECTED_SHA=$(shasum -a 256 "$FIXTURE" | awk '{print $1}')
STORED="$ESRD_HOME/dev/resources/image/${EXPECTED_SHA}.png"
[[ -f "$STORED" ]] || fail "expected stored file at $STORED"

# 5. Assert refs.jsonl has one entry
REFS="$ESRD_HOME/dev/resources/image/${EXPECTED_SHA}.refs.jsonl"
[[ $(wc -l < "$REFS") == "1" ]] || fail "expected 1 ref, got $(wc -l < "$REFS")"

# 6. Connect to cc McpController SSE and assert notification carries the path
SSE_FRAME=$(timeout 5 curl -N "http://localhost:$ESRD_PORT/mcp/$SESSION_ID" \
                            -H "Accept: text/event-stream" | head -10)
echo "$SSE_FRAME" | grep -q '"kind":"image"' || fail "no image kind in SSE"
echo "$SSE_FRAME" | grep -q "$STORED" || fail "no path in SSE"

ok "scenario 20 PASSED"
```

- [ ] **Step 3: Run scenario, verify PASS**

```bash
bash tests/e2e/scenarios/20_feishu_inbound_multimedia.sh
```

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/scenarios/20_feishu_inbound_multimedia.sh tests/e2e/fixtures/screenshot.png
git commit -m "test(e2e): scenario 20 Feishu inbound multimedia

Operator sends PNG via mock_feishu, asserts content-addressed
storage + SSE attachment notification reaches cc. Per spec
2026-05-08 PR-2 acceptance."
```

---

### Task 2.8: PRD-04 §F14 / §10.1 wording rewrite + docs sync

**Files:**
- Modify: `docs/superpowers/prds/04-adapters.md`
- Modify: `docs/notes/esr-uri-grammar.md`
- Create: `docs/notes/multimedia-protocol.md`
- Modify: `docs/notes/claude-code-channels-reference.md`
- Modify: `docs/architecture.md`
- Modify: `README.md`
- Modify: `docs/futures/todo.md`

- [ ] **Step 1: Edit PRD-04 §F14**

In `docs/superpowers/prds/04-adapters.md` find F14 (line ~74) and rewrite the directive output:

OLD: `directive downloads to ~/.esrd/<instance>/uploads/<chat_id>/<file_name> and returns {"ok": True, "result": {"path": ...}}`

NEW: `directive downloads bytes via lark and stores via esr.resource.media.store at $ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>; returns {"ok": True, "result": {"uri": "esr://...", "sha256": "...", "path": "<absolute>"}}`

Add a footnote: `Storage layout migrated 2026-05-08 from chat-keyed uploads/ to content-addressed resources/. See docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md.`

- [ ] **Step 2: Edit `docs/notes/esr-uri-grammar.md`**

Add new row to "Registered types - Path-style RESTful forms" table:

```
| `resources` | `esr://default@localhost/resources/image/<sha256>.png` | content-addressed media storage; `<media_type>/<sha256>.<ext>` |
```

Update "Where URIs are built today" with: `Esr.Resource.Media.store/3 — resources/<media_type>/<sha256>.<ext>; Esr.Uri.build_resource builder`.

- [ ] **Step 3: Create `docs/notes/multimedia-protocol.md`**

```markdown
# Multimedia content protocol

**Date:** 2026-05-08
**Spec:** [2026-05-08-multimedia-content-protocol-design](../superpowers/specs/2026-05-08-multimedia-content-protocol-design.md)

## Envelope shape

All peer-to-peer non-text messages carry:
- `msg_type`: `"image" | "file" | "audio"` (audio future)
- `content`: an `esr://<env>@<host>/resources/<media_type>/<sha256>.<ext>` URI
- `meta`: flat string-keyed map (channel-attribute discipline)

For text: `content` is the text body string; no URI involved.

## Adding a new media type

1. **URI grammar**: extend `@allowed_exts` in `runtime/lib/esr/uri.ex` and the Python mirror.
2. **Phaser**: implement `Esr.Resource.Media.<X>Phaser` (Elixir) + `esr.resource.media.<x>_phaser` (Python). Register in `PhaserRegistry`.
3. **Plugin manifests**: each plugin that handles the new type adds it to `declares.media_types.{inbound,outbound}` (and the Python `esr.toml` mirror).
4. **Tests**: unit tests for the new Phaser; e2e if a new flow is exercised.

## Storage layout

`$ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>` —
bytes (SoT). `<sha256>.refs.jsonl` — append-only ref history. No
`.meta.json` in MVP (future GC pass produces it).

## Failure modes

| Where | What | Recovery |
|---|---|---|
| Resolver | wrong env | `:wrong_env`, dropped |
| Resolver | file gone | `:not_found`, dropped |
| Phaser | unsupported target | `{:error, {:unsupported_target, x}}` |
| Routing | downstream doesn't declare type | dropped + sender-keyed throttled DM |
```

- [ ] **Step 4: Edit `docs/notes/claude-code-channels-reference.md`**

Append section:

```markdown
## Attachment notification shape

Non-text envelopes reach Claude TUI as `notifications/claude/channel`
with:
- `content`: stub like `[image attachment]`
- `meta.kind`: `"image" | "file"`
- `meta.path`: absolute filesystem path on the esrd host

Claude consumes via the Read tool (multimodal for image; text for
small text files).
```

- [ ] **Step 5: Edit `docs/architecture.md`**

Add `Esr.Resource.Media.*` subtree to "Module tree". Add scenario 20 row to "E2E coverage map".

- [ ] **Step 6: Edit `README.md`**

Add scenario 20 to E2E table.

- [ ] **Step 7: Edit `docs/futures/todo.md`**

In "Pending — design discussions before PR", strike the "Feishu file / image / audio inbound" row (now done for image+file). Add:

```
| Audio Phaser + Feishu audio inbound/outbound | spec deferred 2026-05-08 | cc TUI doesn't natively consume audio bytes; surface as path for claude to dispatch other tools |
| Resource GC | spec deferred 2026-05-08 | Esr.Resource.Media.RefIndex.gc_loop/0; refs[]=[] + last_seen > 30d |
| Other Feishu media types: video/post/interactive/sticker/share_chat | spec deferred 2026-05-08 | each is one Phaser + parser tweak after current spec lands |
```

- [ ] **Step 8: Commit docs**

```bash
git add docs/superpowers/prds/04-adapters.md docs/notes/esr-uri-grammar.md docs/notes/multimedia-protocol.md docs/notes/claude-code-channels-reference.md docs/architecture.md README.md docs/futures/todo.md
git commit -m "docs: multimedia protocol — PRD-04 rewrite + new field-note + scenario 20

Updates PRD-04 §F14 (download_file output contract), adds
docs/notes/multimedia-protocol.md, surfaces resources URI in
esr-uri-grammar.md, adds attachment notification section to
claude-code-channels-reference.md. Closes 'Feishu file/image/audio
inbound' row in todo.md (image+file done; audio deferred)."
```

---

### Phase 2 Acceptance Gate

- [ ] All Phase 1 tests still green
- [ ] Phase 2 unit tests green: `(cd runtime && mix test test/esr/resource/media test/esr_web test/esr/plugins/feishu)`
- [ ] Adapter Python tests green: `(cd adapters/feishu && uv run pytest tests/ -v)`
- [ ] **e2e scenario 20 passes**: `bash tests/e2e/scenarios/20_feishu_inbound_multimedia.sh`
- [ ] Manual smoke: drop a real PNG into a real Feishu chat connected to a dev esrd; cc McpController SSE shows `meta.kind=image` + `meta.path`; the path file exists with original bytes.

---

## Phase 3 — Outbound MVP (PR-3)

### Task 3.1: Esr.Entity.CCProxy — outbound store + URI envelope

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/cc_proxy.ex`
- Modify: `runtime/test/esr/plugins/claude_code/cc_proxy_test.exs`

- [ ] **Step 1: Read current cc_proxy outbound paths**

```bash
grep -n 'send_file\|forward\|outbound\|tool_invoke' runtime/lib/esr/plugins/claude_code/cc_proxy.ex | head -20
```

- [ ] **Step 2: Failing test**

```elixir
test "send_file invokes Esr.Resource.Media.store and emits URI envelope" do
  # Setup: PluginRegistry.register("feishu", %{outbound: [:image, :file]})
  # Setup: a tmpdir PNG file
  # Setup: state with a known chat_id
  
  # Trigger: dispatch_tool_invoke("send_file", %{"chat_id" => "oc_xx", "file_path" => tmppng}, ...)
  
  # Assert: an envelope is emitted with msg_type="image", content starting with "esr://...resources/image/..."
  # Assert: the same sha256 file exists at $ESRD_HOME/test/resources/image/<sha>.png
end

test "send_file rejects when feishu doesn't declare outbound for the type" do
  # Setup: PluginRegistry.register("feishu", %{outbound: []})  # no image
  # Trigger: dispatch_tool_invoke("send_file", %{"chat_id" => "oc", "file_path" => tmppng}, ...)
  # Assert: tool_result reply with ok=false, error mentions "outbound"
end

test "send_file rejects extension-less path" do
  # tmpfile has no extension
  # Assert: ok=false, error "no extension"
end
```

- [ ] **Step 3: Run, fail.**

- [ ] **Step 4: Implement outbound branch**

In `runtime/lib/esr/plugins/claude_code/cc_proxy.ex`, locate the existing outbound `send_file` handler (or create one if absent — note the actual outbound today bypasses this proxy and goes directly to FCP per `feishu_chat_proxy.ex:480`). Per spec D4: introduce a CCProxy step that **first** stores + builds URI envelope, then forwards.

Pseudo-code for the new outbound path (modify whichever function dispatches outbound from cc to feishu):

```elixir
defp dispatch_send_file(args, req_id, channel_pid, state) do
  with {:ok, file_path} <- fetch_required(args, "file_path"),
       {:ok, chat_id}   <- fetch_required(args, "chat_id"),
       {:ok, media_type} <- infer_media_type(file_path),
       :ok              <- check_outbound_capability(state.target_plugin, media_type),
       {:ok, %{uri: uri, sha256: sha}} <-
         Esr.Resource.Media.store(media_type, file_path,
                                  %{source_actor: "cc", session_id: state.session_id,
                                    chat_id: chat_id}) do
    envelope = %{
      msg_type: to_string(media_type),
      content: uri,
      meta: %{
        chat_id: chat_id,
        sha256: sha,
        original_filename: Path.basename(file_path)
      }
    }
    forward_to_chat_proxy(envelope, state)
    reply_tool_result(channel_pid, req_id, true, %{"dispatched" => true})
  else
    {:error, :no_extension} ->
      reply_tool_result(channel_pid, req_id, false, nil, %{"type" => "no_extension"})
    {:error, {:unsupported_outbound, kind}} ->
      reply_tool_result(channel_pid, req_id, false, nil,
                         %{"type" => "unsupported_outbound", "kind" => to_string(kind)})
    err ->
      reply_tool_result(channel_pid, req_id, false, nil,
                         %{"type" => "store_failed", "detail" => inspect(err)})
  end
  state
end

defp infer_media_type(path) do
  case path |> Path.extname() |> String.downcase() do
    "" -> {:error, :no_extension}
    ext when ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"] -> {:ok, :image}
    _other -> {:ok, :file}
  end
end

defp check_outbound_capability(plugin_name, media_type) do
  if Esr.Resource.Media.PluginRegistry.supports?(plugin_name, :outbound, media_type) do
    :ok
  else
    {:error, {:unsupported_outbound, media_type}}
  end
end
```

Note: the current code at `feishu_chat_proxy.ex:480-524` does the read+base64 work. **That code stays.** This new code at CCProxy runs *before* the envelope reaches FCP; FCP's existing handler is updated in Task 3.2 to receive a URI-shaped envelope and resolve it back to a path.

- [ ] **Step 5: Run, pass**

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/plugins/claude_code/cc_proxy.ex runtime/test/esr/plugins/claude_code/cc_proxy_test.exs
git commit -m "feat(cc_proxy): outbound send_file via Esr.Resource.Media.store + URI envelope

Spec 2026-05-08 PR-3 §Outbound flow ③. Stores at upstream peer
boundary; preserves α-wire downstream (FCP unchanged here, updated
in next task)."
```

---

### Task 3.2: FeishuChatProxy outbound — resolve URI → existing α-wire

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:480-524`
- Modify: `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs`

- [ ] **Step 1: Failing test**

```elixir
test "send_file outbound branch resolves URI envelope and emits existing α-wire to sidecar" do
  # Setup: tmp PNG stored via Esr.Resource.Media.store
  # Inbound to FCP outbound: envelope %{msg_type: "image", content: stored_uri,
  #                                      meta: %{chat_id: "oc_xx", original_filename: "x.png"}}
  
  # Mock emit_to_feishu_app_proxy to capture the args
  
  # Assert: emitted args have shape {chat_id, file_name, content_b64, sha256}
  # Assert: content_b64 decodes to original bytes
  # Assert: sha256 matches the URI's sha256
end
```

- [ ] **Step 2: Run, fail.**

- [ ] **Step 3: Modify the existing dispatch_tool_invoke("send_file", ...)**

The current code at `feishu_chat_proxy.ex:480` reads `args["file_path"]` and calls `read_file_for_send`. Update to **also accept** an envelope-shaped input (URI in `args["content"]` / `args["uri"]`) and resolve it first:

```elixir
defp dispatch_tool_invoke("send_file", args, req_id, channel_pid, state) do
  file_path = case args do
    %{"uri" => uri} when is_binary(uri) ->
      case Esr.Resource.Media.resolve(uri) do
        {:ok, p} -> p
        {:error, reason} -> {:error, reason}
      end
    %{"file_path" => fp} -> fp
    _ -> {:error, "missing uri or file_path"}
  end

  case file_path do
    {:error, reason} ->
      reply_tool_result(channel_pid, req_id, false, nil,
                        %{"type" => "resolve_failed", "detail" => inspect(reason)})

    path when is_binary(path) ->
      # existing read_file_for_send + emit_to_feishu_app_proxy unchanged
      chat_id = Map.get(args, "chat_id") || state.chat_id
      case read_file_for_send(path) do
        {:ok, file_name, content_b64, sha256} ->
          _ = emit_to_feishu_app_proxy(
                %{
                  "kind" => "send_file",
                  "args" => %{
                    "chat_id" => chat_id,
                    "file_name" => file_name,
                    "content_b64" => content_b64,
                    "sha256" => sha256
                  }
                },
                state
              )
          reply_tool_result(channel_pid, req_id, true, %{"dispatched" => true})

        {:error, reason} ->
          reply_tool_result(channel_pid, req_id, false, nil,
                            %{"type" => "read_failed", "message" => inspect(reason)})
      end
  end
  state
end
```

Note: the **Python sidecar `_send_file` directive is untouched**. It still consumes `{chat_id, file_name, content_b64, sha256}` as before.

- [ ] **Step 4: Run, pass**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs
git commit -m "feat(feishu.fcp): send_file accepts URI envelope; resolves to local path

Spec 2026-05-08 PR-3 §Outbound flow ④. URI envelope path: resolve →
existing read_file_for_send → existing α-wire to Python sidecar
(unchanged). file_path arg still works as legacy path for direct
operator use."
```

---

### Task 3.3: E2E scenario 21 — cc outbound multimedia

**Files:**
- Create: `tests/e2e/scenarios/21_cc_outbound_multimedia.sh`

- [ ] **Step 1: Write scenario 21**

`tests/e2e/scenarios/21_cc_outbound_multimedia.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCENARIO_NAME="21_cc_outbound_multimedia"
source "$(dirname "$0")/common.sh"

fresh_esrd_home
boot_esrd_dev
boot_mock_feishu
register_feishu_adapter

# Bootstrap
ESRD_DEV esr user add operator
# ... session setup

# Place fixture PNG
FIXTURE="$(dirname "$0")/../fixtures/screenshot.png"

# Trigger send_file via the McpController POST endpoint
# (simulates claude calling the tool)
RESP=$(curl -s -X POST "http://localhost:$ESRD_PORT/mcp/$SESSION_ID" \
            -H 'Content-Type: application/json' \
            -d "$(jq -n --arg path "$FIXTURE" --arg chat "$CHAT_ID" \
                  '{jsonrpc:"2.0", id:1, method:"tools/call",
                    params:{name:"send_file", arguments:{file_path:$path, chat_id:$chat}}}')")

echo "$RESP" | grep -q '"dispatched":true' || fail "send_file dispatch failed: $RESP"

# Wait for mock_feishu to record the upload + send
sleep 1
POSTS=$(curl -s "http://localhost:$MOCK_FEISHU_PORT/_admin/recent_posts")
echo "$POSTS" | jq -e '.[0].msg_type == "image"' || fail "no image post recorded"

# Verify the file is also stored in resources/
EXPECTED_SHA=$(shasum -a 256 "$FIXTURE" | awk '{print $1}')
STORED="$ESRD_HOME/dev/resources/image/${EXPECTED_SHA}.png"
[[ -f "$STORED" ]] || fail "expected stored file at $STORED"

ok "scenario 21 PASSED"
```

- [ ] **Step 2: Run scenario**

```bash
bash tests/e2e/scenarios/21_cc_outbound_multimedia.sh
```

- [ ] **Step 3: Update README + architecture**

Add scenario 21 to `README.md` E2E table and `docs/architecture.md` E2E coverage map.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/scenarios/21_cc_outbound_multimedia.sh README.md docs/architecture.md
git commit -m "test(e2e): scenario 21 cc outbound multimedia

Claude tool send_file dispatches PNG; assert mock_feishu records the
post AND the file lives at content-addressed resources/."
```

---

### Phase 3 Acceptance Gate

- [ ] All previous tests still green
- [ ] `(cd runtime && mix test)` full green
- [ ] `(cd py && uv run --with pytest --with pytest-asyncio --with pyyaml pytest tests/ ../tests/integration/ -v)`
- [ ] `(cd adapters/feishu && uv run pytest tests/ -v)`
- [ ] `bash tests/e2e/scenarios/20_feishu_inbound_multimedia.sh`
- [ ] `bash tests/e2e/scenarios/21_cc_outbound_multimedia.sh`
- [ ] Manual smoke: claude `send_file` from a real session shows the image in real Feishu chat

---

## Final Acceptance — All Phases

Before opening any PR:

- [ ] Run the full test matrix top-to-bottom from a clean `cd /Users/h2oslabs/Workspace/esr/.claude/worktrees/multimedia-pipeline`:

```bash
(cd runtime && mix test) && \
(cd py && uv run --with pytest --with pytest-asyncio --with pyyaml pytest tests/ ../tests/integration/ -v) && \
(cd adapters/feishu && uv run pytest tests/ -v) && \
for s in 20 21; do bash tests/e2e/scenarios/${s}_*.sh; done
```

- [ ] Confirm all spec decisions D1-D7 are reflected in the code:
  - D1: All new modules under `Esr.Resource.Media.*` / `esr.resource.media.*`
  - D2: URI top-level `resources/<media_type>/<sha256>.<ext>`
  - D3: `<sha>.refs.jsonl` append-only; tmp+rename for bytes
  - D4: send_file outbound — Elixir CCProxy stores; FCP→sidecar α-wire unchanged
  - D5: `media_types` opt-in; loader does not reject when absent
  - D6: throttle key `(sender_id, kind)`
  - D7: `text` not in `media_types` lists

- [ ] Open three PRs (one per phase) targeting `dev` branch per `docs/dev-flow.md` (not main; per memory `feedback_pr_targets_dev_not_main.md`).
