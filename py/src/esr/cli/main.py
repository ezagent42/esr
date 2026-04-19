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

    # Import the pattern module so @command registers it
    spec = importlib.util.spec_from_file_location(f"_pattern_{name}", pattern_path)
    if spec is None or spec.loader is None:
        click.echo(f"could not load {pattern_path}", err=True)
        raise click.exceptions.Exit(code=1)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    from esr.command import compile_to_yaml, compile_topology

    topo = compile_topology(name)
    out = output or (Path("patterns") / ".compiled" / f"{name}.yaml")
    out.parent.mkdir(parents=True, exist_ok=True)
    compile_to_yaml(topo, out)
    click.echo(f"compiled {name} → {out}")


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
