"""
Cross-check plugin manifest media_types declarations.

For each plugin that has BOTH a runtime Elixir manifest
(runtime/lib/esr/plugins/<name>/manifest.yaml) AND a Python adapter
manifest (adapters/<name>/esr.toml), verify that the
declares.media_types in the yaml matches the [media_types] in the
toml.

Per spec docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md
§4.2:
- both absent → no check (non-multimedia plugin)
- both present → strict equality on sorted inbound/outbound lists
- asymmetric → CI failure (always a bug)
"""
from pathlib import Path

import pytest
import tomllib  # py 3.11+
import yaml


REPO = Path(__file__).resolve().parents[2]


def _plugins_with_python_adapter():
    """Return [(plugin_name, manifest_yaml_path, esr_toml_path), ...]
    for plugins that have BOTH an Elixir manifest and a Python adapter
    manifest."""
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


_pairs = _plugins_with_python_adapter()


@pytest.mark.parametrize(
    "name,manifest_path,toml_path",
    _pairs,
    ids=[p[0] for p in _pairs],
)
def test_media_types_consistency(name, manifest_path, toml_path):
    yaml_data = yaml.safe_load(manifest_path.read_text())
    yaml_mt = (yaml_data or {}).get("declares", {}).get("media_types")

    toml_data = tomllib.loads(toml_path.read_text())
    toml_mt = toml_data.get("media_types")

    if yaml_mt is None and toml_mt is None:
        # both absent — non-multimedia plugin; no check
        return

    assert yaml_mt is not None and toml_mt is not None, (
        f"asymmetric media_types presence in plugin '{name}': "
        f"manifest.yaml media_types={yaml_mt!r} esr.toml media_types={toml_mt!r}"
    )

    yaml_in = sorted(yaml_mt.get("inbound", []))
    yaml_out = sorted(yaml_mt.get("outbound", []))
    toml_in = sorted(toml_mt.get("inbound", []))
    toml_out = sorted(toml_mt.get("outbound", []))

    assert yaml_in == toml_in, (
        f"plugin '{name}' inbound drift: "
        f"manifest.yaml={yaml_in} vs esr.toml={toml_in}"
    )
    assert yaml_out == toml_out, (
        f"plugin '{name}' outbound drift: "
        f"manifest.yaml={yaml_out} vs esr.toml={toml_out}"
    )


def test_at_least_one_plugin_pair_exists():
    """Sanity: ensures the discovery walk found something. If this
    fails, either the directory layout has changed (and the test
    needs updating) or all plugins are pure-Elixir-only with no
    Python sidecar."""
    assert len(_pairs) >= 1, (
        f"no plugin pairs found at {REPO}/runtime/lib/esr/plugins/<name>/manifest.yaml + "
        f"{REPO}/adapters/<name>/esr.toml"
    )
