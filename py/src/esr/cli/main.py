"""``esr`` CLI entry point (PRD 07)."""

from __future__ import annotations

import importlib.util
import os
import tomllib
from pathlib import Path

import click
import yaml

# --- Context file helpers ----------------------------------------------


def _context_path() -> Path:
    return Path(os.path.expanduser("~")) / ".esr" / "context"


def _load_context() -> dict[str, str]:
    """Read ~/.esr/context; env ``ESR_CONTEXT`` takes precedence."""
    env = os.environ.get("ESR_CONTEXT")
    if env:
        return {"endpoint": _endpoint_from_host_port(env)}
    path = _context_path()
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text()) or {}
    return dict(data)


def _save_context(host_port: str) -> None:
    """Persist the selected endpoint to ~/.esr/context."""
    path = _context_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        yaml.safe_dump({"endpoint": _endpoint_from_host_port(host_port)}),
        encoding="utf-8",
    )


def _endpoint_from_host_port(host_port: str) -> str:
    return f"ws://{host_port}/adapter_hub/socket"


def _host_port_from_endpoint(endpoint: str) -> str:
    prefix = "ws://"
    suffix = "/adapter_hub/socket"
    if endpoint.startswith(prefix):
        endpoint = endpoint[len(prefix):]
    if endpoint.endswith(suffix):
        endpoint = endpoint[: -len(suffix)]
    return endpoint


# --- CLI groups --------------------------------------------------------


@click.group()
def cli() -> None:
    """``esr`` — command-line entry to a running esrd."""


@cli.command("use")
@click.argument("host_port", required=False)
def use(host_port: str | None) -> None:
    """Set or print the target esrd endpoint (PRD 07 F01).

    With a ``host:port`` argument, persists ``~/.esr/context`` so future
    commands target that endpoint. Without arguments, prints the current
    endpoint (env ``ESR_CONTEXT`` overrides the file).
    """
    if host_port:
        _save_context(host_port)
        click.echo(f"set context: {host_port}")
        return

    ctx = _load_context()
    endpoint = ctx.get("endpoint")
    if not endpoint:
        click.echo(
            "no context set — run `esr use <host:port>` to select an esrd endpoint",
            err=True,
        )
        raise click.exceptions.Exit(code=1)
    click.echo(_host_port_from_endpoint(endpoint))


# --- adapter / handler / cmd groups ------------------------------------


@cli.group()
def adapter() -> None:
    """Adapter install / instance / list operations."""


@adapter.command("install")
@click.argument(
    "source",
    type=click.Path(exists=True, file_okay=False, dir_okay=True, path_type=Path),
)
def adapter_install(source: Path) -> None:
    """Validate a local adapter package (PRD 07 F03).

    v0.1 scope: parse ``esr.toml``, verify the source package exists,
    and run ``esr.verify.capability.scan_adapter`` against the
    adapter module. Full fetch-and-register into
    ``~/.esrd/<instance>/adapters.yaml`` lands with runtime wiring
    (Phase 8). This command is offline.
    """
    from esr.verify.capability import scan_adapter

    manifest = source / "esr.toml"
    if not manifest.exists():
        click.echo(f"no esr.toml at {manifest}", err=True)
        raise click.exceptions.Exit(code=1)
    with manifest.open("rb") as f:
        data = tomllib.load(f)

    name = data.get("name", source.name)
    module = data.get("module", "")
    allowed_io = data.get("allowed_io", {})

    # module is like "esr_<name>.adapter" → file src/<first>/<second>.py
    if module:
        parts = module.split(".")
        src_path = source / "src" / parts[0] / (parts[-1] + ".py")
        if src_path.exists():
            violations = scan_adapter(src_path, allowed_io)
            if violations:
                click.echo(
                    f"{name}: capability violations against declared allowed_io:",
                    err=True,
                )
                for v in violations:
                    click.echo(f"  {src_path}:{v.lineno}: {v.message}", err=True)
                raise click.exceptions.Exit(code=1)

    click.echo(f"validated adapter {name}")


@adapter.command("list")
def adapter_list() -> None:
    """List installed adapter types (PRD 07 F05).

    Scans ``adapters/<name>/esr.toml`` under the current working
    directory — this is a read-only offline operation (PRD 07 F23).
    """
    _print_manifest_names(Path("adapters"))


@cli.group()
def handler() -> None:
    """Handler install / list / remove operations."""


@handler.command("install")
@click.argument(
    "source",
    type=click.Path(exists=True, file_okay=False, dir_okay=True, path_type=Path),
)
def handler_install(source: Path) -> None:
    """Validate a local handler package (PRD 07 F06).

    v0.1 scope: parse ``esr.toml``, run ``scan_imports`` on every
    ``.py`` file under ``src/``. Full fetch-and-register into
    ``~/.esrd/<instance>/handlers.yaml`` lands with runtime wiring
    (Phase 8). This command is offline.
    """
    from esr.verify.purity import scan_imports

    manifest = source / "esr.toml"
    if not manifest.exists():
        click.echo(f"no esr.toml at {manifest}", err=True)
        raise click.exceptions.Exit(code=1)
    with manifest.open("rb") as f:
        data = tomllib.load(f)

    name = data.get("name", source.name)
    # Also accept the handler's own src package import (e.g.
    # esr_handler_feishu_app) as allowed during its own self-scan.
    extra = {f"esr_handler_{name}"} if name else set()

    any_violation = False
    for py in sorted((source / "src").rglob("*.py")):
        for v in scan_imports(py, extra_allowed=extra):
            click.echo(f"{py}:{v.lineno}: {v.message}", err=True)
            any_violation = True
    if any_violation:
        raise click.exceptions.Exit(code=1)

    click.echo(f"validated handler {name}")


@handler.command("list")
def handler_list() -> None:
    """List installed handlers (PRD 07 F07)."""
    _print_manifest_names(Path("handlers"))


@cli.group()
def cmd() -> None:
    """Command (pattern) install / compile / run / stop operations."""


@cmd.command("list")
def cmd_list() -> None:
    """List available patterns (PRD 07 F09 subset).

    Reads ``patterns/*.py`` files; each file's name (minus ``.py``)
    is the command name. Fully offline.
    """
    root = Path("patterns")
    if not root.is_dir():
        click.echo("no patterns/ directory found", err=True)
        raise click.exceptions.Exit(code=1)
    names = sorted(p.stem for p in root.glob("*.py"))
    for name in names:
        click.echo(name)


@cmd.command("install")
@click.argument("source", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option(
    "--compiled-dir",
    type=click.Path(file_okay=False, path_type=Path),
    default=None,
    help="Directory for compiled YAML (default: patterns/.compiled/).",
)
def cmd_install(source: Path, compiled_dir: Path | None) -> None:
    """Install a pattern: resolve deps + compile to YAML (PRD 07 F08).

    Checks that every adapter type and handler referenced by the
    pattern's nodes has an installed manifest under ``adapters/`` /
    ``handlers/`` (PRD 06 F08). Missing deps → list + exit nonzero.
    On success, writes ``<compiled-dir>/<name>.yaml`` (PRD 06 F09).
    """
    from esr.command import COMMAND_REGISTRY, compile_to_yaml, compile_topology

    name = source.stem
    COMMAND_REGISTRY.pop(name, None)
    spec = importlib.util.spec_from_file_location(f"_pattern_{name}", source)
    if spec is None or spec.loader is None:
        click.echo(f"could not load {source}", err=True)
        raise click.exceptions.Exit(code=1)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    topo = compile_topology(name)

    missing = _missing_dependencies(topo)
    if missing:
        click.echo(
            f"{name}: missing dependencies — install them first:", err=True
        )
        for dep in missing:
            click.echo(f"  - {dep}", err=True)
        raise click.exceptions.Exit(code=1)

    out_dir = compiled_dir or (Path("patterns") / ".compiled")
    out = out_dir / f"{name}.yaml"
    out.parent.mkdir(parents=True, exist_ok=True)
    compile_to_yaml(topo, out)
    click.echo(f"installed {name} → {out}")


@cmd.command("show")
@click.argument("name")
@click.option(
    "--compiled-dir",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
    default=Path("patterns/.compiled"),
    help="Directory holding compiled YAMLs (default: patterns/.compiled/).",
)
def cmd_show(name: str, compiled_dir: Path) -> None:
    """Pretty-print a compiled command's topology (PRD 06 F10)."""
    path = compiled_dir / f"{name}.yaml"
    if not path.exists():
        click.echo(f"no compiled topology for {name!r} at {path}", err=True)
        raise click.exceptions.Exit(code=1)

    data = yaml.safe_load(path.read_text())
    click.echo(f"command: {data['name']} (schema v{data.get('schema_version', 1)})")
    params = data.get("params") or []
    if params:
        click.echo(f"params: {', '.join(params)}")
    nodes = data.get("nodes") or []
    click.echo(f"nodes ({len(nodes)}):")
    for n in nodes:
        line = f"  - {n['id']}  [{n['actor_type']} / {n['handler']}]"
        if n.get("adapter"):
            line += f"  adapter={n['adapter']}"
        if n.get("depends_on"):
            line += f"  depends_on={n['depends_on']}"
        click.echo(line)
        if n.get("init_directive"):
            click.echo(f"      init_directive: {n['init_directive']}")
    edges = data.get("edges") or []
    if edges:
        click.echo(f"edges ({len(edges)}):")
        for src, dst in edges:
            click.echo(f"  {src} → {dst}")


@cmd.command("compile")
@click.argument("name")
@click.option(
    "--output",
    "-o",
    type=click.Path(dir_okay=False, path_type=Path),
    default=None,
    help="Where to write the compiled YAML (default: patterns/.compiled/<name>.yaml)",
)
def cmd_compile(name: str, output: Path | None) -> None:
    """Compile a pattern .py file to canonical YAML (PRD 07 F10)."""
    pattern_path = Path("patterns") / f"{name}.py"
    if not pattern_path.exists():
        click.echo(f"pattern {name!r} not found at {pattern_path}", err=True)
        raise click.exceptions.Exit(code=1)

    from esr.command import COMMAND_REGISTRY, compile_to_yaml, compile_topology

    # Drop any stale registration so re-compile is idempotent across
    # CLI invocations in the same process (tests, programmatic callers).
    COMMAND_REGISTRY.pop(name, None)

    spec = importlib.util.spec_from_file_location(f"_pattern_{name}", pattern_path)
    if spec is None or spec.loader is None:
        click.echo(f"could not load {pattern_path}", err=True)
        raise click.exceptions.Exit(code=1)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    topo = compile_topology(name)
    out = output or (Path("patterns") / ".compiled" / f"{name}.yaml")
    out.parent.mkdir(parents=True, exist_ok=True)
    compile_to_yaml(topo, out)
    click.echo(f"compiled {name} → {out}")


# --- lint (F14) --------------------------------------------------------


@cli.command("lint")
@click.argument(
    "path",
    type=click.Path(exists=True, file_okay=False, dir_okay=True, path_type=Path),
)
def lint(path: Path) -> None:
    """Run the import allow-list purity scan over a directory tree (PRD 07 F14).

    Walks every ``.py`` file under ``path`` and applies
    ``esr.verify.purity.scan_imports``. Prints each violation as
    ``<file>:<lineno>: <message>`` and exits nonzero if any
    violation surfaced.
    """
    from esr.verify.purity import scan_imports

    any_violation = False
    for py in sorted(path.rglob("*.py")):
        violations = scan_imports(py)
        for v in violations:
            click.echo(f"{py}:{v.lineno}: {v.message}")
            any_violation = True

    if any_violation:
        raise click.exceptions.Exit(code=1)


# --- Dependency resolution for cmd install (PRD 06 F08) ---------------


def _extract_type_name(raw: str) -> str:
    """Strip template suffix from an adapter name.

    The convention is ``<type>-<instance_suffix>`` or
    ``<type>-{{param}}`` — in either case we only need the leading
    ``<type>`` for the "is this installed?" check.
    """
    if "{{" in raw:
        raw = raw.split("{{", 1)[0].rstrip("-")
    return raw.split("-", 1)[0] if "-" in raw else raw


def _missing_dependencies(topo: object) -> list[str]:
    """Return a sorted list of missing adapter/handler dependencies.

    Adapter reference: ``node.adapter`` (a string, possibly templated).
    Handler reference: ``node.handler`` is ``<handler_name>.<entry>`` —
    the handler manifest lives at ``handlers/<handler_name>/``.
    """
    missing: list[str] = []
    seen_adapters: set[str] = set()
    seen_handlers: set[str] = set()

    adapters_dir = Path("adapters")
    handlers_dir = Path("handlers")

    # Use duck-typing: topo has a .nodes attr
    for n in getattr(topo, "nodes", ()):
        if n.adapter:
            type_name = _extract_type_name(str(n.adapter))
            if type_name and type_name not in seen_adapters:
                seen_adapters.add(type_name)
                if not (adapters_dir / type_name / "esr.toml").exists():
                    missing.append(f"adapter:{type_name}")
        if n.handler:
            h_name = str(n.handler).split(".", 1)[0]
            if h_name and h_name not in seen_handlers:
                seen_handlers.add(h_name)
                if not (handlers_dir / h_name / "esr.toml").exists():
                    missing.append(f"handler:{h_name}")

    return sorted(missing)


# --- Shared helpers for list commands ---------------------------------


def _print_manifest_names(root: Path) -> None:
    """List every ``<root>/<name>/esr.toml``'s ``name`` field."""
    if not root.is_dir():
        click.echo(f"no {root}/ directory found", err=True)
        raise click.exceptions.Exit(code=1)
    names: list[str] = []
    for manifest in sorted(root.glob("*/esr.toml")):
        with manifest.open("rb") as f:
            data = tomllib.load(f)
        names.append(str(data.get("name", manifest.parent.name)))
    for name in names:
        click.echo(name)
