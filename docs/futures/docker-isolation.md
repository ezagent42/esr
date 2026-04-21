# Future: Docker-based ESR Isolation (deferred)

**Status:** deferred; stub authored during phase DI-14.
**Related:** dev/prod-isolation spec §13 ("Future work" bullet "Docker isolation"); operator guide `docs/operations/dev-prod-isolation.md`.

---

## Why this is deferred (and what we shipped instead)

The dev/prod-isolation work (phases DI-1..DI-14) solves the **parallel-iteration** problem — running a prod esrd and a dev esrd side by side without cross-contamination — via **env-driven filesystem separation**: `~/.esrd/` vs `~/.esrd-dev/`, two launchd labels, one `ESR_INSTANCE` env var threading through Elixir + Python, and per-branch ephemeral esrds under `/tmp/esrd-<branch>/`.

This is intentionally *not* container-based. Full Docker isolation is a meaningfully harder problem because three assumptions the current architecture makes get broken by a container boundary:

### 1. `cc_tmux` adapter spawns host tmux

The CC adapter's default implementation (`adapters/cc_tmux/`) shells out to `tmux new-session …` on the host. Inside a container, this either:

- Doesn't see the host's tmux server at all (no socket passthrough), OR
- Needs `/tmp/tmux-<uid>/default` bind-mounted from the host, which then defeats the isolation — a rogue session inside the container can send commands to the host operator's real tmux.

A Docker-isolated ESR would need a different CC-spawn strategy (probably `docker exec` into a CC-dedicated container, or full replacement with a pure MCP client that doesn't need tmux at all). That's its own design doc.

### 2. MCP bridge launch order

Claude Code, running on the host, spawns the `esr-cc-mcp` Python bridge as a local subprocess. That bridge connects to esrd over a UNIX-ish TCP socket (`ws://127.0.0.1:<port>`). If esrd is inside a container:

- The container must expose the Phoenix port on `127.0.0.1:<host-port>` (doable, but the reverse — CC needs to know which host-port maps to which container-esrd — requires a port-registry).
- The MCP bridge must start AFTER the container is healthy. Today the bridge's reconnect loop (`_resolve_url` + backoff) papers over this; with containers, the "is the container ready" signal is orthogonal to "is the port file written".
- Orphan-adoption on esrd reboot (DI-14 track DI-N) relies on `/tmp/esrd-<branch>/` being visible to the Elixir runtime. In a container, that path is container-local unless you bind-mount `/tmp` — which is exactly the kind of host-contamination Docker isolation is supposed to prevent.

### 3. macOS fsnotify reliability across bind mounts

The Admin Watcher, CapabilitiesWatcher, and SessionRouter all depend on `:file_system` (FSEvents backend on macOS) to pick up `capabilities.yaml` / `routing.yaml` / admin-queue `pending/` writes within ~1 s. FSEvents is famously unreliable across bind-mounted volumes:

- Writes from the container to a bind-mount sometimes fire events on the host, sometimes don't.
- Writes from the host to a bind-mount rarely propagate events inside the container.
- The fallback (poll every N seconds) is available but it inverts the latency contract — we'd lose the "admin grants are live within 2s" property the cap subsystem advertises.

This is fixable (mount with `:delegated` or similar, poll-backed FileSystem, or abandon fsnotify entirely for a poll loop), but the effort is much larger than the env-based isolation's sed-level path refactor.

---

## What would need to change (sketch)

Should the need for full container isolation ever materialise — most plausible driver: **operators running genuinely different versions of ESR code in parallel**, not just different configs, where env-based `~/.esrd/` separation isn't enough — the changes fall into three buckets:

1. **Image + compose topology.** Build a base `esr-runtime` image (Elixir + Phoenix, no secrets baked in). For each instance, derive a child image with the version-pinned adapter set and a mounted `ESRD_HOME`. One `docker-compose.yml` per `<instance>`.
2. **CC bridge adaptation.** Replace `cc_tmux` with a containerised CC client, OR run CC on the host and have it connect to the container's exposed Phoenix port (requires the host-port-registry mentioned above). The operator guide's §4.4 session lifecycle becomes a docker-compose invocation rather than a shell script.
3. **File-watch strategy.** Either:
   - Replace `:file_system` with a poll-based watcher (`Esr.*.Watcher` gets a `:poll_interval` config, defaults to 1 s) — simplest, ~2% CPU cost per watcher.
   - Or, keep FSEvents and require `:delegated` bind mounts on macOS, document that Linux Docker Desktop on Mac has permanent fsnotify gaps, and fall back to the above on failure.

The `Esr.Paths` module already reads `ESRD_HOME` + `ESR_INSTANCE` from the environment, so path refactoring is already complete — the remaining work is at the container + OS-level file-watch seam.

---

## Summary: when does this become worth doing?

Env-based isolation is the right answer when:

- You need dev + prod of the **same** ESR codebase on one machine.
- Your adapters are host-native (tmux CC, local MCP bridge).
- You control the files in `~/.esrd*` and can tolerate a shared macOS kernel / userspace.

Docker isolation is the right answer when:

- You need **two genuinely different versions** of the ESR codebase running simultaneously (e.g. an older `main` for a contracted customer while developing a breaking rewrite on `next`), AND
- You can either run CC inside the container or accept a host-port-registry for CC → container bridging, AND
- You're prepared to swap FSEvents for a poll-based watcher.

As of phase DI-14 none of these conditions apply to our target users, so we ship env-based isolation and park this stub for when they do.

---

*End of docker-isolation deferral note.*
