"""``esr`` CLI entry point (PRD 07)."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import tomllib
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import click
import yaml

from esr.ipc.channel_client import ChannelClient

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


@cli.command("status")
def status() -> None:
    """Probe runtime reachability (PRD 07 F02).

    Connects a short-lived ChannelClient to the current context's
    adapter_hub socket. Prints ``<endpoint> — OK`` on success, or
    ``<endpoint> — UNREACHABLE (<reason>)`` with a non-zero exit
    code so shells / scripts can detect it.
    """
    ctx = _load_context()
    endpoint = ctx.get("endpoint")
    if not endpoint:
        click.echo(
            "no context set — run `esr use <host:port>` to select an esrd endpoint",
            err=True,
        )
        raise click.exceptions.Exit(code=1)

    # Phoenix expects the ``/websocket`` suffix at the transport URL;
    # context stores the socket path only.
    ws_url = endpoint + "/websocket"
    client = ChannelClient(ws_url)

    async def _probe() -> None:
        await asyncio.wait_for(client.connect(), timeout=5.0)
        await client.close()

    try:
        asyncio.run(_probe())
    except Exception as exc:  # noqa: BLE001 — any connect failure is UNREACHABLE
        click.echo(f"{endpoint} — UNREACHABLE ({type(exc).__name__}: {exc})")
        raise click.exceptions.Exit(code=1) from exc

    click.echo(f"{endpoint} — OK")


@cli.group()
def scenario() -> None:
    """E2E scenario orchestration (PRD 07 F20)."""


@scenario.command("run")
@click.argument("name")
@click.option("--verbose", "-v", is_flag=True, help="Per-step output.")
def scenario_run(name: str, verbose: bool) -> None:
    """Run an E2E scenario from ``scenarios/<name>.yaml`` (spec v2.1 §4.2).

    Each step under ``steps:`` is executed:
    1. Run ``command`` as a subprocess (shell=True) with
       ``timeout_sec`` deadline.
    2. Compare exit status to ``expect_exit`` (default 0).
    3. Match stdout against ``expect_stdout_match`` regex.
    On any miss, report the step failed and continue. Exit 0 iff every
    step passed; exit 1 otherwise.
    """
    import re
    import subprocess as _sp

    path = Path.cwd() / "scenarios" / f"{name}.yaml"
    if not path.exists():
        click.echo(f"scenario {name!r} not found at {path}", err=True)
        raise click.exceptions.Exit(code=1)

    try:
        data: Any = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        click.echo(f"invalid scenario YAML ({name!r}): {exc}", err=True)
        raise click.exceptions.Exit(code=1) from exc

    if not isinstance(data, dict):
        click.echo(f"invalid scenario {name!r}: top-level must be a mapping", err=True)
        raise click.exceptions.Exit(code=1)

    steps = data.get("steps") or []
    if not isinstance(steps, list):
        click.echo(f"invalid scenario {name!r}: steps must be a list", err=True)
        raise click.exceptions.Exit(code=1)

    setup_steps = data.get("setup") or []
    teardown_steps = data.get("teardown") or []

    # Run setup first; a failing setup aborts without running any step.
    for i, sstep in enumerate(setup_steps, 1):
        if not isinstance(sstep, dict) or not isinstance(sstep.get("command"), str):
            click.echo(f"scenario {name!r}: setup[{i}] missing command", err=True)
            raise click.exceptions.Exit(code=1)
        s_timeout = int(sstep.get("timeout_sec", 30))
        s_expect_exit = int(sstep.get("expect_exit", 0))
        try:
            sp = _sp.run(sstep["command"], shell=True, capture_output=True,
                         text=True, timeout=s_timeout, check=False)
        except _sp.TimeoutExpired:
            click.echo(f"scenario {name!r}: setup step {i} timed out", err=True)
            raise click.exceptions.Exit(code=1) from None
        if sp.returncode != s_expect_exit:
            click.echo(
                f"scenario {name!r}: setup step {i} failed "
                f"(exit={sp.returncode}, wanted {s_expect_exit})",
                err=True,
            )
            click.echo(sp.stdout, err=True)
            click.echo(sp.stderr, err=True)
            raise click.exceptions.Exit(code=1)
        if verbose:
            click.echo(f"  ✓ setup[{i}]  {sstep['command'][:60]!r}")
            click.echo(sp.stdout, nl=False)

    passed = 0
    failures: list[str] = []
    for i, step in enumerate(steps, 1):
        if not isinstance(step, dict):
            failures.append(f"step {i}: not a mapping")
            continue
        cmd = step.get("command")
        pattern = step.get("expect_stdout_match")
        expect_exit = int(step.get("expect_exit", 0))
        timeout_sec = int(step.get("timeout_sec", 30))
        step_id = step.get("id", f"step-{i}")

        if not isinstance(cmd, str):
            failures.append(f"{step_id}: missing 'command'")
            continue
        if not isinstance(pattern, str):
            failures.append(f"{step_id}: missing 'expect_stdout_match'")
            continue

        try:
            proc = _sp.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout_sec, check=False)
        except _sp.TimeoutExpired:
            failures.append(f"{step_id}: timeout after {timeout_sec}s")
            if verbose:
                click.echo(f"  ✗ {step_id}  TIMEOUT")
            continue

        if proc.returncode != expect_exit:
            failures.append(
                f"{step_id}: exit={proc.returncode} (wanted {expect_exit})"
            )
            if verbose:
                click.echo(f"  ✗ {step_id}  exit={proc.returncode}")
            continue

        if not re.search(pattern, proc.stdout):
            failures.append(
                f"{step_id}: stdout did not match {pattern!r}"
            )
            if verbose:
                click.echo(f"  ✗ {step_id}  stdout did not match {pattern!r}")
                click.echo(f"    stdout: {proc.stdout[:200]!r}")
            continue

        passed += 1
        if verbose:
            click.echo(f"  ✓ {step_id}")

    # Teardown always runs (even after step failures) — best-effort cleanup.
    for i, tstep in enumerate(teardown_steps, 1):
        if not isinstance(tstep, dict) or not isinstance(tstep.get("command"), str):
            continue
        t_timeout = int(tstep.get("timeout_sec", 30))
        try:
            _sp.run(tstep["command"], shell=True, capture_output=True,
                    text=True, timeout=t_timeout, check=False)
        except _sp.TimeoutExpired:
            if verbose:
                click.echo(f"  ! teardown[{i}] timed out")

    total = len(steps)
    if failures:
        click.echo(f"scenario {name!r}: {passed}/{total} steps PASSED "
                   f"— {len(failures)} FAILED")
        for f in failures:
            click.echo(f"  FAIL: {f}")
        raise click.exceptions.Exit(code=1)
    click.echo(f"scenario {name!r}: {passed}/{total} steps PASSED")


# --- adapter / handler / cmd groups ------------------------------------


@cli.group()
def adapter() -> None:
    """Adapter install / instance / list operations."""


@adapter.command("add", context_settings={"ignore_unknown_options": True})
@click.argument("instance_name")
@click.option("--type", "adapter_type", required=True, help="Adapter type name.")
@click.argument("config_args", nargs=-1, type=click.UNPROCESSED)
def adapter_add(
    instance_name: str, adapter_type: str, config_args: tuple[str, ...]
) -> None:
    """Register a new adapter instance (PRD 07 F04).

    Flag pairs (``--key value`` or ``--key=value``) are collected into
    the instance's AdapterConfig. Writes to
    ``~/.esrd/<instance>/adapters.yaml`` — the "esrd instance"
    here is hardcoded to ``default`` in v0.1 (separated-instance
    support lives with Phase 1 F18 esrd multi-instance config).
    """
    # Parse the trailing pass-through args into a config dict.
    cfg_dict = _parse_config_flags(config_args)

    cfg_path = Path(os.path.expanduser("~")) / ".esrd" / "default" / "adapters.yaml"
    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    doc: dict[str, Any] = {"instances": {}}
    if cfg_path.exists():
        loaded = yaml.safe_load(cfg_path.read_text()) or {}
        doc = loaded if isinstance(loaded, dict) else {"instances": {}}
        if "instances" not in doc:
            doc["instances"] = {}

    if instance_name in doc["instances"]:
        click.echo(
            f"adapter instance {instance_name!r} already exists — use remove first",
            err=True,
        )
        raise click.exceptions.Exit(code=1)

    doc["instances"][instance_name] = {"type": adapter_type, "config": cfg_dict}
    cfg_path.write_text(yaml.safe_dump(doc, sort_keys=True))
    click.echo(f"added {instance_name} ({adapter_type})")


def _parse_config_flags(args: tuple[str, ...]) -> dict[str, str]:
    """Turn ``--key value`` / ``--key=value`` pairs into a dict.

    Underscore conversion: ``--app-id`` → ``app_id`` so flag names can
    be kebab-case (click convention) while pydantic/config names stay
    snake_case.
    """
    out: dict[str, str] = {}
    i = 0
    while i < len(args):
        tok = args[i]
        if tok.startswith("--"):
            if "=" in tok:
                key, val = tok[2:].split("=", 1)
            elif i + 1 < len(args):
                key, val = tok[2:], args[i + 1]
                i += 1
            else:
                key, val = tok[2:], ""
            out[key.replace("-", "_")] = val
        i += 1
    return out


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


def _response(reply: dict[str, Any]) -> dict[str, Any]:
    """Extract the ``response`` dict from a phx_reply envelope. Surfaces
    ``status != "ok"`` as :class:`RuntimeError`."""
    status = reply.get("status")
    if status != "ok":
        raise RuntimeError(f"runtime returned status={status!r}; reply={reply!r}")
    resp = reply.get("response") or {}
    return resp if isinstance(resp, dict) else {}


def _submit_cmd_run(artifact: dict[str, Any], params: dict[str, str]) -> dict[str, Any]:
    """Send a compiled artifact + params to the runtime for instantiation."""
    from esr.cli.runtime_bridge import call_runtime
    name = artifact.get("name", "unknown")
    resp = _response(call_runtime(
        topic=f"cli:run/{name}",
        payload={"artifact": artifact, "params": params},
    ))
    data = resp.get("data") or {}
    return {
        "name": data.get("name", name),
        "params": data.get("params", params),
        "peer_ids": data.get("peer_ids", []),
    }


def _submit_cmd_stop(name: str, params: dict[str, str]) -> dict[str, Any]:
    """Deactivate a running instantiation by (name, params) via the runtime."""
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(
        topic=f"cli:stop/{name}",
        payload={"name": name, "params": params},
    ))
    data = resp.get("data") or {}
    return {
        "name": data.get("name", name),
        "params": data.get("params", params),
        "stopped_peer_ids": data.get("stopped_peer_ids", []),
    }


def _parse_param_bindings(bindings: tuple[str, ...]) -> dict[str, str]:
    """Parse ``--param k=v`` repeats into a dict; surface ``key=value`` format errors."""
    out: dict[str, str] = {}
    for binding in bindings:
        if "=" not in binding:
            raise click.BadParameter(f"invalid --param {binding!r}: expected key=value")
        k, _, v = binding.partition("=")
        out[k] = v
    return out


def _submit_trace(
    *, session: str | None, last: str | None, filter: str | None  # noqa: A002
) -> list[dict[str, Any]]:
    """Query the runtime telemetry-buffer ring via ``cli:trace`` topic."""
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(
        topic="cli:trace",
        payload={"session": session, "last": last, "filter": filter},
    ))
    entries = resp.get("entries", [])
    return entries if isinstance(entries, list) else []


def _submit_debug(action: str, args: dict[str, Any]) -> dict[str, Any]:
    """Debug control ops via ``cli:debug`` topic."""
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(topic=f"cli:debug/{action}", payload=args))
    data = resp.get("data") or {}
    return data if isinstance(data, dict) else {}


def _submit_drain(*, timeout: str | None) -> dict[str, Any]:
    """Graceful shutdown via ``cli:drain`` topic."""
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(
        topic="cli:drain", payload={"timeout": timeout}, timeout_sec=120.0,
    ))
    data = resp.get("data") or {}
    return data if isinstance(data, dict) else {}


def _stream_telemetry(
    *, pattern: str, format: str  # noqa: A002
) -> Iterator[dict[str, Any]]:
    """Stream matching telemetry events via ``cli:telemetry`` subscription.

    Phase 8c iterates: proper streaming needs a dedicated subscription API
    on ChannelClient. For now, issues a single cli:telemetry call that
    returns the currently-buffered batch and yields those events. Live
    subscription tail is Phase 8d work.
    """
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(
        topic=f"cli:telemetry/{pattern}",
        payload={"format": format},
    ))
    events = resp.get("events", [])
    if isinstance(events, list):
        for event in events:
            if isinstance(event, dict):
                yield event


def _submit_actors(action: str, arg: str | None) -> Any:
    """Actor-registry queries via ``cli:actors`` topic."""
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(
        topic=f"cli:actors/{action}", payload={"arg": arg},
    ))
    return resp.get("data")


def _submit_deadletter(action: str, arg: str | None) -> Any:
    """Deadletter control ops via ``cli:deadletter`` topic."""
    from esr.cli.runtime_bridge import call_runtime
    resp = _response(call_runtime(
        topic=f"cli:deadletter/{action}", payload={"arg": arg},
    ))
    return resp.get("data")


@cmd.command("run")
@click.argument("name")
@click.option(
    "--param",
    "params",
    multiple=True,
    help="Param binding (``key=value``); repeat for multiple params.",
)
@click.option(
    "--compiled-dir",
    type=click.Path(path_type=Path),
    default=None,
    help="Override the .compiled/ lookup path (default: ~/.esrd/default/commands/.compiled).",
)
def cmd_run(name: str, params: tuple[str, ...], compiled_dir: Path | None) -> None:
    """Instantiate a registered command (PRD 07 F11).

    Loads the compiled artifact from ``.compiled/<name>.yaml``,
    validates declared params are provided, and submits to the
    runtime. Prints the instantiation handle on stdout. Timeout 30 s
    per PRD.
    """
    root = compiled_dir or (
        Path(os.path.expanduser("~")) / ".esrd" / "default" / "commands" / ".compiled"
    )
    path = root / f"{name}.yaml"
    if not path.exists():
        click.echo(f"command {name!r} not found at {path}", err=True)
        raise click.exceptions.Exit(code=1)

    artifact = yaml.safe_load(path.read_text()) or {}

    # Parse --param k=v flags into a dict.
    params_map: dict[str, str] = {}
    for binding in params:
        if "=" not in binding:
            click.echo(f"invalid --param {binding!r}: expected key=value", err=True)
            raise click.exceptions.Exit(code=1)
        k, _, v = binding.partition("=")
        params_map[k] = v

    declared = artifact.get("params") or []
    missing = [p for p in declared if p not in params_map]
    if missing:
        click.echo(
            f"missing params: {', '.join(missing)} (pass with --param {missing[0]}=<value>)",
            err=True,
        )
        raise click.exceptions.Exit(code=1)

    try:
        handle = _submit_cmd_run(artifact, params_map)
    except TimeoutError as exc:
        click.echo(
            f"runtime timeout ({exc}); run `esr status` to check reachability",
            err=True,
        )
        raise click.exceptions.Exit(code=1) from exc
    except NotImplementedError as exc:
        click.echo(f"cmd run: {exc}", err=True)
        raise click.exceptions.Exit(code=1) from exc

    peer_ids = handle.get("peer_ids", [])
    click.echo(
        f"instantiated {handle['name']!r} → peers={','.join(peer_ids)}"
    )
    # Per-peer actor_id= lines — give live-signature sig-B for scenario
    # steps so 'esr cmd run' output regex-matches without shell plumbing.
    for pid in peer_ids:
        click.echo(f"  actor_id={pid}")


@cmd.command("stop")
@click.argument("name")
@click.option(
    "--param",
    "params",
    multiple=True,
    help="Param binding (``key=value``); must match the live (name, params) key.",
)
def cmd_stop(name: str, params: tuple[str, ...]) -> None:
    """Deactivate a live topology instantiation (PRD 07 F12).

    Identifies the target by ``(name, params)`` — the same key
    Registry.register used — and triggers Registry.deactivate on
    the runtime, cascading tear-down in reverse depends_on order
    per spec §6.5.
    """
    try:
        params_map = _parse_param_bindings(params)
    except click.BadParameter as exc:
        click.echo(str(exc), err=True)
        raise click.exceptions.Exit(code=1) from exc

    try:
        handle = _submit_cmd_stop(name, params_map)
    except TimeoutError as exc:
        click.echo(
            f"runtime timeout ({exc}); run `esr status` to check reachability",
            err=True,
        )
        raise click.exceptions.Exit(code=1) from exc
    except NotImplementedError as exc:
        click.echo(f"cmd stop: {exc}", err=True)
        raise click.exceptions.Exit(code=1) from exc

    stopped = handle.get("stopped_peer_ids", [])
    click.echo(
        f"stopped {handle['name']!r} → peers={','.join(stopped)}"
    )
    for pid in stopped:
        click.echo(f"  actor_id={pid}")


@cmd.command("restart")
@click.argument("name")
@click.option(
    "--param",
    "params",
    multiple=True,
    help="Param binding (``key=value``); identifies the target and primes the restart.",
)
@click.option(
    "--compiled-dir",
    type=click.Path(path_type=Path),
    default=None,
    help="Override the .compiled/ lookup path.",
)
def cmd_restart(name: str, params: tuple[str, ...], compiled_dir: Path | None) -> None:
    """Stop and immediately re-instantiate a topology (PRD 07 F13).

    State preservation is a spec §6.5 guarantee: PeerServer state
    persisted via F18 ETS survives the stop/run boundary, so a
    restart keeps handler counters / dedup sets intact.
    """
    root = compiled_dir or (
        Path(os.path.expanduser("~")) / ".esrd" / "default" / "commands" / ".compiled"
    )
    path = root / f"{name}.yaml"
    if not path.exists():
        click.echo(f"command {name!r} not found at {path}", err=True)
        raise click.exceptions.Exit(code=1)

    artifact = yaml.safe_load(path.read_text()) or {}

    try:
        params_map = _parse_param_bindings(params)
    except click.BadParameter as exc:
        click.echo(str(exc), err=True)
        raise click.exceptions.Exit(code=1) from exc

    declared = artifact.get("params") or []
    missing = [p for p in declared if p not in params_map]
    if missing:
        click.echo(
            f"missing params: {', '.join(missing)} (pass with --param {missing[0]}=<value>)",
            err=True,
        )
        raise click.exceptions.Exit(code=1)

    try:
        _submit_cmd_stop(name, params_map)  # idempotent; no-op if not running
        handle = _submit_cmd_run(artifact, params_map)
    except TimeoutError as exc:
        click.echo(
            f"runtime timeout ({exc}); run `esr status` to check reachability",
            err=True,
        )
        raise click.exceptions.Exit(code=1) from exc
    except NotImplementedError as exc:
        click.echo(f"cmd restart: {exc}", err=True)
        raise click.exceptions.Exit(code=1) from exc

    click.echo(
        f"restarted {handle['name']!r} → peers={','.join(handle.get('peer_ids', []))}"
    )


@cli.command("drain")
@click.option(
    "--timeout",
    default=None,
    help="Max wait per topology (e.g. ``30s``, ``2m``). Default: server-side config.",
)
def drain(timeout: str | None) -> None:
    """Gracefully stop every live topology (PRD 07 F21).

    Traverses topologies in reverse depends_on order, deactivating
    each. Blocks until either every topology has stopped or the
    timeout expires. Reports a summary on stdout and exits non-zero
    if any topology failed to stop in time.
    """
    result = _submit_drain(timeout=timeout)
    drained = result.get("drained", [])
    timeouts = result.get("timeouts", [])
    duration_ms = result.get("duration_ms", 0)

    if not drained and not timeouts:
        click.echo(f"nothing to drain (0 topologies live); took {duration_ms}ms")
        return

    click.echo(
        f"drained {len(drained)} topolog{'y' if len(drained) == 1 else 'ies'} "
        f"in {duration_ms}ms"
    )
    if timeouts:
        suffix = "y" if len(timeouts) == 1 else "ies"
        click.echo(f"timeout: {len(timeouts)} topolog{suffix} did not stop:")
        for t in timeouts:
            click.echo(f"  {t.get('name', '?')} params={t.get('params', {})}")
        raise click.exceptions.Exit(code=1)


@cli.group()
def debug() -> None:
    """Admin / debug commands (PRD 07 F18)."""


@debug.command("replay")
@click.argument("msg_id")
def debug_replay(msg_id: str) -> None:
    """Re-process a previously-received event by its envelope id."""
    result = _submit_debug("replay", {"msg_id": msg_id})
    click.echo(f"replayed {result.get('replayed', msg_id)!r}")


@debug.command("inject")
@click.option("--to", "to_actor", required=True, help="Target actor_id.")
@click.option("--event", "event_json", required=True, help="Event JSON body.")
def debug_inject(to_actor: str, event_json: str) -> None:
    """Inject a synthetic event straight into a peer's mailbox."""
    try:
        event = json.loads(event_json)
    except json.JSONDecodeError as exc:
        click.echo(f"invalid --event JSON: {exc}", err=True)
        raise click.exceptions.Exit(code=1) from exc

    result = _submit_debug("inject", {"to": to_actor, "event": event})
    click.echo(f"injected into {result.get('actor_id', to_actor)!r}")


@debug.command("pause")
@click.argument("actor_id")
def debug_pause(actor_id: str) -> None:
    """Pause a peer (inbound events queue until resume)."""
    _submit_debug("pause", {"actor_id": actor_id})
    click.echo(f"paused {actor_id!r}")


@debug.command("resume")
@click.argument("actor_id")
def debug_resume(actor_id: str) -> None:
    """Resume a paused peer, draining queued events FIFO."""
    result = _submit_debug("resume", {"actor_id": actor_id})
    drained = result.get("drained", 0)
    click.echo(f"resumed {actor_id!r} (drained {drained} queued events)")


@cli.group()
def telemetry() -> None:
    """Live telemetry subscriptions (PRD 07 F17)."""


@telemetry.command("subscribe")
@click.argument("pattern")
@click.option(
    "--format",
    "fmt",
    type=click.Choice(["json", "table"]),
    default="table",
    help="Output format: table (one line per event) or json (ndjson).",
)
def telemetry_subscribe(pattern: str, fmt: str) -> None:
    """Stream events matching ``<pattern>`` as they fire (PRD 07 F17).

    Long-running — terminates on Ctrl-C. Pattern is the Elixir
    dotted-event shape (e.g. ``esr.handler.*``).
    """
    for event in _stream_telemetry(pattern=pattern, format=fmt):
        if fmt == "json":
            click.echo(json.dumps(event))
        else:
            ts = event.get("ts", "-")
            name = event.get("event", "?")
            actor = event.get("actor_id", "-")
            click.echo(f"{ts}  {name}  actor_id={actor}")


@cli.command("trace")
@click.option("--session", default=None, help="Scope to one actor_id / session.")
@click.option("--last", default=None, help="Time window (e.g. ``5m``, ``1h``).")
@click.option(
    "--filter", "filter_pattern", default=None,
    help="Event-name regex filter.",
)
def trace(session: str | None, last: str | None, filter_pattern: str | None) -> None:
    """Read the runtime telemetry-buffer ring (PRD 07 F16).

    All options narrow the server-side query; the CLI prints the
    returned events one-per-line as ``<ts> <event>  actor_id=<id>``
    with remaining kwargs echoed.
    """
    entries = _submit_trace(session=session, last=last, filter=filter_pattern)
    if not entries:
        click.echo("no events matched")
        return
    for entry in entries:
        ts = entry.get("ts", "-")
        event = entry.get("event", "?")
        actor = entry.get("actor_id", "-")
        extras = {
            k: v for k, v in entry.items()
            if k not in {"ts", "event", "actor_id"}
        }
        suffix = "  " + " ".join(f"{k}={v}" for k, v in extras.items()) if extras else ""
        click.echo(f"{ts}  {event}  actor_id={actor}{suffix}")


@cli.group()
def actors() -> None:
    """Query the live actor registry (PRD 07 F15)."""


@actors.command("list")
def actors_list() -> None:
    """Enumerate every live actor as ``<actor_id>  <actor_type>``."""
    entries = _submit_actors("list", None)
    if not entries:
        click.echo("no actors live")
        return
    for entry in entries:
        click.echo(f"{entry['actor_id']}  {entry.get('actor_type', '?')}")


@actors.command("tree")
def actors_tree() -> None:
    """Render the depends_on hierarchy as an indented tree."""
    data = _submit_actors("tree", None)
    children: dict[str, list[str]] = {}
    for src, dst in data.get("edges", []):
        children.setdefault(src, []).append(dst)

    def _print(node: str, depth: int) -> None:
        prefix = "  " * depth + ("└─ " if depth > 0 else "")
        click.echo(f"{prefix}{node}")
        for child in children.get(node, []):
            _print(child, depth + 1)

    for root in data.get("roots", []):
        _print(root, 0)


@actors.command("inspect")
@click.argument("actor_id")
def actors_inspect(actor_id: str) -> None:
    """Dump one actor's state + metadata."""
    info = _submit_actors("inspect", actor_id)
    click.echo(f"{info['actor_id']}  type={info.get('actor_type', '?')}"
               f"  paused={info.get('paused', False)}")
    state = info.get("state", {})
    for k, v in state.items():
        click.echo(f"  {k} = {v!r}")


@actors.command("logs")
@click.argument("actor_id")
@click.option("--follow", "-f", is_flag=True, help="Stream new lines (Phase 8 only).")
def actors_logs(actor_id: str, follow: bool) -> None:
    """Recent telemetry / events for this actor."""
    _ = follow  # v0.1 returns a snapshot; live --follow is Phase 8.
    entries = _submit_actors("logs", actor_id)
    if not entries:
        click.echo(f"no recent activity for {actor_id!r}")
        return
    for entry in entries:
        click.echo(
            f"{entry.get('ts', '-')}  {entry.get('event', '?')}  "
            f"msg={entry.get('msg', '-')}"
        )


@cli.group()
def deadletter() -> None:
    """DeadLetter queue inspection + recovery (PRD 07 F19)."""


@deadletter.command("list")
def deadletter_list() -> None:
    """List every entry currently in the runtime's dead-letter queue."""
    entries = _submit_deadletter("list", None)
    if not entries:
        click.echo("deadletter queue is empty")
        return
    for entry in entries:
        click.echo(
            f"{entry['id']}  {entry.get('reason', '?')}  "
            f"source={entry.get('source', '-')}  ts={entry.get('ts_unix_ms', '-')}"
        )


@deadletter.command("retry")
@click.argument("entry_id")
def deadletter_retry(entry_id: str) -> None:
    """Re-enqueue a dead-letter entry for another delivery attempt."""
    result = _submit_deadletter("retry", entry_id)
    click.echo(f"retried {result.get('retried', entry_id)!r}")


@deadletter.command("flush")
def deadletter_flush() -> None:
    """Empty the dead-letter queue (admin op — logs a warning)."""
    result = _submit_deadletter("flush", None)
    click.echo(f"flushed {result.get('flushed', 0)} entries")


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
