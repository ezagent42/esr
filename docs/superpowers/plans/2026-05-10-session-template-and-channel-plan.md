# SessionTemplate + Channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote session wiring out of plugin-private code into a declarative bundle/template artifact; formalize per-session transport peers as `Esr.Channel`. Plugin manifest gains `channels:` + `agent_kinds:` blocks; bundles are first-class artifacts (`runtime/lib/esr/bundles/<name>/`); `agents.yaml` dissolves.

**Architecture:** Five-layer split (Agent type / Channel / Bundle / SessionTemplate / Agent instance). Plugin ships primitives (manifest yaml). Bundle ships stories (one template per bundle dir). Operator can drop ad-hoc templates without making a bundle. ESR core ships zero templates.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / yaml_elixir + Ymlr (already in deps post unified-grammar) / ExUnit + ScenarioBash for e2e.

**Spec:** `docs/superpowers/specs/2026-05-10-session-template-and-channel.md` (rev-3, user-approved 2026-05-10). Sister spec: `2026-05-09-yaml-layout-v2-per-thing-directories.md` (storage layout, in-flight in user's parallel work).

**Migration philosophy:** Hardcut per user directive. ESR is not yet in production use; no v2/legacy/translation-layer adapters. Each phase that changes a contract (agents.yaml dissolution, agent_instance.json split, etc) deletes the old shape entirely. No dual-read paths.

**Branch strategy:** Stack of ~10 PRs off `origin/dev`, each phase its own PR. Admin-merge after subagent + user review per memory rule. Phase 7 hard-depends on yaml-v2 spec having merged; if it hasn't, Phase 7 stalls (no on-the-fly adapter).

---

## File map

### New top-level dirs

- `runtime/lib/esr/channel/` — channel behaviour + registry
- `runtime/lib/esr/bundle/` — bundle manifest + loader + registry
- `runtime/lib/esr/session_template/` — template schema + loader + registry + flow node registry
- `runtime/lib/esr/bundles/` — built-in bundles (sibling to `plugins/`)

### Phase 1 (Channel infra)

- Create: `runtime/lib/esr/channel/behaviour.ex` — `Esr.Channel`
- Create: `runtime/lib/esr/channel/registry.ex` — `Esr.Channel.Registry` (ETS)
- Modify: `runtime/lib/esr/plugin/manifest.ex` — add `channels:` block parsing
- Modify: `runtime/lib/esr/plugin/loader.ex` — register channels at boot
- Test: `runtime/test/esr/channel/behaviour_test.exs`
- Test: `runtime/test/esr/channel/registry_test.exs`
- Test: `runtime/test/esr/plugin/manifest_channels_test.exs`

### Phase 2 (claude_code MCP HTTP Channel)

- Create: `runtime/lib/esr/plugins/claude_code/channels/mcp_http.ex` — `Esr.Plugins.ClaudeCode.Channels.McpHttp`
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml` — add `channels:` block
- Modify: `runtime/lib/esr_web/mcp_controller.ex` — route through Channel where appropriate (no behavior change)
- Test: `runtime/test/esr/plugins/claude_code/channels/mcp_http_test.exs`

### Phase 3 (feishu chat Channel)

- Create: `runtime/lib/esr/plugins/feishu/channels/chat_proxy.ex` — `Esr.Plugins.Feishu.Channels.ChatProxy`
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml` — add `channels:` block
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — extract channel-shaped half; module renamed `Esr.Entity.FeishuChatProxy` → `Esr.Plugins.Feishu.FeishuChatProxy` to align file path (locked-decision in Phase 3 task list)
- Update callers of the renamed module (find via grep)
- Test: `runtime/test/esr/plugins/feishu/channels/chat_proxy_test.exs`
- Adjust existing `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs` for the rename

### Phase 4 (Bundle infra + first bundle + scenario 27, 29)

- Create: `runtime/lib/esr/bundle/manifest.ex` — `Esr.Bundle.Manifest` parser
- Create: `runtime/lib/esr/bundle/loader.ex` — `Esr.Bundle.Loader`
- Create: `runtime/lib/esr/bundle/registry.ex` — `Esr.Bundle.Registry` ETS
- Create: `runtime/lib/esr/session_template/parser.ex` — `Esr.SessionTemplate.Parser`
- Create: `runtime/lib/esr/session_template/registry.ex` — `Esr.SessionTemplate.Registry` ETS
- Create: `runtime/lib/esr/session_template/flow_node_registry.ex` — `Esr.SessionTemplate.FlowNodeRegistry` (built-in flow nodes: `MentionParser`, `route_to_agent`)
- Create: `runtime/lib/esr/bundles/feishu-cc/manifest.yaml` — first bundle manifest
- Create: `runtime/lib/esr/bundles/feishu-cc/template.yaml` — first template
- Modify: `runtime/lib/esr/commands/plugin/install.ex` — recognize bundle vs plugin; if `template.yaml` present in target dir → bundle path
- Test: `runtime/test/esr/bundle/manifest_test.exs`
- Test: `runtime/test/esr/bundle/loader_test.exs`
- Test: `runtime/test/esr/session_template/parser_test.exs`
- Test: `runtime/test/esr/session_template/registry_test.exs`
- Test: `runtime/test/esr/commands/plugin/install_bundle_test.exs`
- E2E: `tests/e2e/scenarios/27_template_dependency_unmet.sh`
- E2E: `tests/e2e/scenarios/29_external_bundle_install.sh`

### Phase 5 (/session:new template= cutover, scenarios 24, 26)

- Modify: `runtime/lib/esr/commands/session/new.ex` — accept `template=` arg; route through template loader instead of hard-coded pipeline
- Modify: `runtime/lib/esr/session/agent_spawner.ex` — agent spawn path takes Channel pids from template instantiation, not hard-coded
- Modify: `runtime/lib/esr/session/agent_instance_supervisor.ex` — accept Channel children alongside CC + PTY
- Delete: hard-coded `Esr.Entity.FeishuChatProxy` spawn from session-creation path (replaced by template-driven Channel instantiation)
- Modify: `runtime/lib/esr/commands/plugin/set.ex` — accept `key=default_template` (so operator can `/plugin:set plugin=session key=default_template value=feishu-cc`)
- Test: `runtime/test/esr/commands/session/new_template_test.exs`
- E2E: `tests/e2e/scenarios/24_template_instantiated_session.sh`
- E2E: `tests/e2e/scenarios/26_operator_template_override.sh`

### Phase 6 (agents.yaml dissolution — 13 consumers)

- Modify: `runtime/lib/esr/application.ex` — `extract_handler_modules/1` reads from plugin manifest agent_kinds[].handler_module instead of agents.yaml
- Modify: `runtime/lib/esr/interface/spawner.ex` — read agent_kinds from plugin registry
- Modify: `runtime/lib/esr/interface/snapshot_registry.ex` — same
- Delete: `runtime/lib/esr/entity/agent/registry.ex` — agents.yaml ETS cache no longer needed (replaced by plugin registry's agent_kinds index)
- Modify: `runtime/lib/esr/yaml/fragment_merger.ex` — multi-layer merge story moves from agents.yaml to plugin-manifest agent_kinds[]
- Modify: `runtime/lib/esr/commands/workspace/remove.ex` — workspace deletion checks read plugin agent_kinds + active instances
- Modify: `runtime/lib/esr/commands/plugin/agent_types.ex` — drop agents.yaml fallback (already partially uses plugin registry)
- Modify: `runtime/lib/esr/resource/capability.ex` — `capabilities_required` source moves to plugin manifest agent_kinds[].capabilities_required
- Modify: `runtime/lib/esr/commands/session/new.ex` — already touched in Phase 5; this phase removes any remaining agents.yaml read
- Modify: `runtime/lib/esr/session/router.ex` — rename `:agents_yaml_reloaded` event → `:agent_kinds_reloaded`; re-source from plugin manifest reload
- Modify: `runtime/lib/esr/session/agent_spawner.ex` — same as spawner; already touched in Phase 5
- Modify: `runtime/lib/esr/plugins/claude_code/cc_process.ex` — moduledoc reference deleted
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml` — moduledoc reference deleted
- **Delete: agents.yaml file itself + its on-disk seed in priv** (after all consumers migrate)
- Test: snapshot before/after cap resolution against representative session spawn (asserts identical resolved cap set)
- Test: existing tests continue to pass after dissolution (no behavior change, just source rename)

### Phase 7 (multi-session-per-instance, scenario 25)

- **Hard dependency: yaml-v2 spec must have merged** (sessions/<sid>/agents/<aid>.json file split). If not, Phase 7 stalls.
- Modify: `runtime/priv/schemas/agent_instance.v1.json` → bump to v2; field `session_id` (singular) → `session_ids` (array of UUIDs); required min length 1
- Migration: one-shot pass over `~/.esrd-<inst>/<inst>/sessions/*/agents/*.json` rewriting `session_id: x` → `session_ids: [x]`; runs at boot if v1 files detected; deletes nothing else
- Modify: `runtime/lib/esr/entity/agent/instance.ex` — struct field `session_id` → `session_ids :: [String.t()]`
- Modify: `runtime/lib/esr/entity/agent/instance_registry.ex` — `add_instance_and_spawn/2` accepts `session_ids` list; `lookup/2` matches if name + any session_id in list matches
- Modify: `runtime/lib/esr/plugins/claude_code/cc_process.ex` — track `current_session_id` per inbound; reply routing uses incoming session
- Modify: cc_mcp tool catalog — add `current_session_id` arg surfaced to claude (so CC can disambiguate users in skill prompts)
- Slash addition: `/agent:add-session session=<sid> name=<n>` — extends an existing instance with a new session
- Test: `runtime/test/esr/entity/agent/instance_multi_session_test.exs`
- E2E: `tests/e2e/scenarios/25_multi_session_per_instance.sh`

### Phase 8 (docs + scenario 28 + CI gate)

- Update: `docs/notes/concepts.md` — rev-11 reflecting bundle as first-class
- Update: `docs/grammar/commands.md` — auto-regenerated (post-Phase 5 it'll naturally reflect new `/session:new template=` arg)
- Create: `docs/grammar/templates.md` — auto-generated reference of registered templates per bundle
- Create: `runtime/lib/mix/tasks/esr.check_bundles.ex` — CI gate validates every bundle's dependencies + template ref integrity
- Modify: `.github/workflows/ci.yml` — add `mix esr.check_bundles` step
- E2E: `tests/e2e/scenarios/28_two_agent_kind_composition.sh` — stub second agent kind validates abstraction
- Update: `docs/manual-checks/` — historical record of "session wiring promoted to bundles" as a closure note

---

## Phase 1 — Channel infrastructure

**Goal:** Ship `Esr.Channel` behaviour + registry + plugin-manifest extension. No existing code paths change. Land independently.

**PR:** `feat/sessiontemplate-phase-1-channel-infra` → `dev`. Estimate ~250 LOC + ~150 LOC tests.

### Task 1.1: Branch + sync

- [ ] **Step 1: Create branch off dev**

```bash
git fetch origin
git checkout -b feat/sessiontemplate-phase-1-channel-infra origin/dev
git --no-pager log -1 --oneline
```

Expected: HEAD on the latest dev commit.

### Task 1.2: `Esr.Channel` behaviour

**Files:**
- Create: `runtime/lib/esr/channel/behaviour.ex`
- Create: `runtime/test/esr/channel/behaviour_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Esr.ChannelTest do
  use ExUnit.Case, async: true

  test "Esr.Channel declares the four required callbacks" do
    callbacks = Esr.Channel.behaviour_info(:callbacks)
    assert {:start_link, 1} in callbacks
    assert {:dispatch, 2} in callbacks
    assert {:subscribe, 3} in callbacks
    # config_schema/0 is optional
    refute {:config_schema, 0} in (Esr.Channel.behaviour_info(:optional_callbacks) -- callbacks)
  end

  test "Esr.Channel has a stub impl that compiles" do
    defmodule Esr.ChannelTest.NoOpChannel do
      @behaviour Esr.Channel
      def start_link(_opts), do: {:ok, self()}
      def dispatch(_pid, _msg), do: :ok
      def subscribe(_pid, _listener, _topic), do: :ok
    end

    assert {:ok, _pid} = Esr.ChannelTest.NoOpChannel.start_link([])
  end
end
```

- [ ] **Step 2: Run test, verify fails**

```bash
cd runtime && mix test test/esr/channel/behaviour_test.exs
```

Expected: fails with `Esr.Channel undefined`.

- [ ] **Step 3: Implement behaviour**

> **Adapter pattern note** (per reviewer Open Q D): `EsrWeb.McpController`
> today uses Phoenix.PubSub broadcasts (`cli:channel/<sid>` topic), not
> pid-targeted dispatch. Phase 2's MCP-as-Channel wrap means the Channel
> pid encapsulates the controller's PubSub: `dispatch/2` on a Channel pid
> does `Phoenix.PubSub.broadcast(EsrWeb.PubSub, topic, msg)`, and
> `subscribe/3` registers a listener pid for forwarding from broadcast →
> direct send. The `pid` arg in the callback signature represents the
> Channel's lifecycle peer, not the wire-level transport.

```elixir
defmodule Esr.Channel do
  @moduledoc """
  Per-session transport peer abstraction. Each Channel impl is a
  GenServer-shaped module shipped by a plugin. Impls live under
  `Esr.Plugins.<plugin>.Channels.<name>`; behaviour requirements
  apply to every impl.

  Channels are supervised under per-session AgentSupervisor with
  `:one_for_all` strategy (M-2.6). Crash → siblings restart in
  lockstep → re-register their pids in the per-session Registry.

  Note on dispatch/2: the `pid` arg is the Channel's GenServer
  lifecycle peer, NOT the wire-level transport. Concrete impls may
  internally route via Phoenix.PubSub broadcast, HTTP POST, etc.
  The Channel pid is the addressable lifecycle handle; the wire
  shape is the impl's choice.
  """

  @callback start_link(opts :: keyword) :: {:ok, pid} | {:error, term}
  @callback dispatch(pid, msg :: term) :: :ok | {:error, term}
  @callback subscribe(pid, listener_pid :: pid, topic :: term) :: :ok
  @callback config_schema() :: map
  @optional_callbacks config_schema: 0
end
```

- [ ] **Step 4: Run test, verify passes**

```bash
cd runtime && mix test test/esr/channel/behaviour_test.exs
```

Expected: 2/2 pass.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/channel/behaviour.ex runtime/test/esr/channel/behaviour_test.exs
git commit -m "channel: add Esr.Channel behaviour"
```

### Task 1.3: `Esr.Channel.Registry` (ETS)

**Files:**
- Create: `runtime/lib/esr/channel/registry.ex`
- Create: `runtime/test/esr/channel/registry_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule Esr.Channel.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Channel.Registry

  setup do
    {:ok, _} = start_supervised(Registry)
    :ok
  end

  test "register/3 + lookup/1 round-trips a (plugin, channel_name) → module mapping" do
    :ok = Registry.register("feishu", "chat_proxy", Esr.Plugins.Feishu.Channels.ChatProxy)
    {:ok, module} = Registry.lookup("feishu.chat_proxy")
    assert module == Esr.Plugins.Feishu.Channels.ChatProxy
  end

  test "lookup/1 with unknown kind returns :not_found" do
    assert :not_found = Registry.lookup("nonexistent.foo")
  end

  test "list_kinds/0 returns every registered (plugin, name) pair" do
    Registry.register("p", "a", Mod1)
    Registry.register("p", "b", Mod2)
    assert {"p.a", Mod1} in Registry.list_kinds()
    assert {"p.b", Mod2} in Registry.list_kinds()
  end

  test "register/3 with same key overwrites" do
    Registry.register("p", "a", Mod1)
    Registry.register("p", "a", Mod2)
    assert {:ok, Mod2} = Registry.lookup("p.a")
  end
end
```

- [ ] **Step 2: Run, verify fails**

```bash
cd runtime && mix test test/esr/channel/registry_test.exs
```

- [ ] **Step 3: Implement**

```elixir
defmodule Esr.Channel.Registry do
  @moduledoc """
  ETS-backed registry mapping `<plugin>.<channel_name>` → module.
  Populated at plugin boot (`Esr.Plugin.Loader` reads each plugin's
  `manifest.yaml` `channels:` block); read concurrently by SessionTemplate
  loader during template registration.
  """

  use GenServer

  @table :esr_channel_kinds

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @spec register(String.t(), String.t(), module) :: :ok
  def register(plugin, channel_name, module)
      when is_binary(plugin) and is_binary(channel_name) and is_atom(module) do
    :ets.insert(@table, {"#{plugin}.#{channel_name}", module})
    :ok
  end

  @spec lookup(String.t()) :: {:ok, module} | :not_found
  def lookup(key) when is_binary(key) do
    case :ets.lookup(@table, key) do
      [{^key, module}] -> {:ok, module}
      [] -> :not_found
    end
  end

  @spec list_kinds() :: [{String.t(), module}]
  def list_kinds do
    :ets.tab2list(@table)
  end
end
```

- [ ] **Step 4: Run, verify passes**

```bash
cd runtime && mix test test/esr/channel/registry_test.exs
```

Expected: 4/4 pass.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/channel/registry.ex runtime/test/esr/channel/registry_test.exs
git commit -m "channel: add Esr.Channel.Registry (ETS)"
```

### Task 1.4: Plugin manifest extension — `channels:` block

**Files:**
- Modify: `runtime/lib/esr/plugin/manifest.ex` (add `channels` field + parser)
- Modify: `runtime/test/esr/plugin/manifest_test.exs` (add channels parsing test) OR new test file

- [ ] **Step 1: Read current manifest module + test**

```bash
grep -n 'defstruct\|@type\|parse_' runtime/lib/esr/plugin/manifest.ex | head -20
```

Find the existing `defstruct` and add `channels: []` field. Find the parsing function (`parse/1` or similar) and add `channels` block parsing.

- [ ] **Step 2: Add `channels` field**

In `runtime/lib/esr/plugin/manifest.ex` `defstruct`, append `channels: []` to the keyword list. Add type spec `channels :: [%{name: String.t(), module: module(), config_schema: map() | nil}]`.

- [ ] **Step 3: Parse `channels:` block**

Add a `parse_channels/1` private function and call from the main parser. Each channel entry must have `name` and `module` (string parsed via `String.to_existing_atom/1` after `Code.ensure_loaded?/1`). `config_schema:` is optional.

- [ ] **Step 4: Add manifest channels test**

```elixir
test "parse/1 with channels: block populates Esr.Plugin.Manifest.channels" do
  yaml = """
  name: test_plugin
  version: 0.1.0
  channels:
    - name: chat_proxy
      module: Esr.Plugins.Feishu.Channels.ChatProxy
    - name: mcp_http
      module: Esr.Plugins.ClaudeCode.Channels.McpHttp
      config_schema:
        type: object
        properties:
          port: {type: integer}
  """

  {:ok, manifest} = Esr.Plugin.Manifest.parse(yaml)
  assert length(manifest.channels) == 2
  assert hd(manifest.channels).name == "chat_proxy"
end
```

- [ ] **Step 5: Run + verify pass**

```bash
cd runtime && mix test test/esr/plugin/manifest_test.exs
```

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/plugin/manifest.ex runtime/test/esr/plugin/manifest_test.exs
git commit -m "manifest: add channels: block parsing"
```

### Task 1.5: Loader integration — register channels at boot

**Files:**
- Modify: `runtime/lib/esr/plugin/loader.ex` (add channel registration step)
- Modify: `runtime/test/esr/plugin/loader_test.exs`

- [ ] **Step 1: Add registration in loader boot path**

Find `Esr.Plugin.Loader` boot/`run_startup/0` flow. Add a step after manifest parse: for each channel in `manifest.channels`, call `Esr.Channel.Registry.register/3`.

- [ ] **Step 2: Test loader registers channels**

```elixir
test "Loader.run_startup/0 registers each enabled plugin's channels" do
  # set up: enable a fixture plugin with 2 channels in its manifest
  # call run_startup
  # assert Registry.list_kinds/0 includes the 2 channels
end
```

- [ ] **Step 3: Run + verify pass**

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/plugin/loader.ex runtime/test/esr/plugin/loader_test.exs
git commit -m "loader: register channels at boot"
```

### Task 1.6: Open Phase 1 PR

- [ ] **Step 1: Push + PR**

```bash
git push -u origin feat/sessiontemplate-phase-1-channel-infra
gh pr create --repo ezagent42/esr --base dev --head feat/sessiontemplate-phase-1-channel-infra --title "feat(sessiontemplate 1/8): Channel behaviour + Registry + manifest channels: block" --body "Phase 1 — pure infrastructure, no behavioral change. Lands Esr.Channel behaviour, Esr.Channel.Registry ETS, plugin manifest channels: block parsing, and Loader integration. Subsequent phases populate this with concrete Channel impls."
```

- [ ] **Step 2: After CI green + subagent review pass, admin-merge**

```bash
gh pr merge --repo ezagent42/esr --admin --squash --delete-branch <PR_NUMBER>
```

---

## Phase 2 — claude_code MCP HTTP Channel

**Goal:** Wrap the existing Elixir MCP HTTP transport (`EsrWeb.McpController`) under `Esr.Channel`. Register in claude_code's plugin manifest. No new transport code — just the behaviour adapter.

**PR:** `feat/sessiontemplate-phase-2-claude-code-mcp-channel` → `dev`. Estimate ~300 LOC + ~150 LOC tests.

### Task 2.1: `Esr.Plugins.ClaudeCode.Channels.McpHttp` impl

**Files:**
- Create: `runtime/lib/esr/plugins/claude_code/channels/mcp_http.ex`
- Create: `runtime/test/esr/plugins/claude_code/channels/mcp_http_test.exs`

- [ ] **Step 1: Failing test (TDD)**

```elixir
defmodule Esr.Plugins.ClaudeCode.Channels.McpHttpTest do
  use ExUnit.Case, async: false

  alias Esr.Plugins.ClaudeCode.Channels.McpHttp

  test "implements Esr.Channel" do
    assert :erlang.function_exported(McpHttp, :start_link, 1)
    assert :erlang.function_exported(McpHttp, :dispatch, 2)
    assert :erlang.function_exported(McpHttp, :subscribe, 3)
  end

  test "start_link/1 returns {:ok, pid}" do
    {:ok, pid} = McpHttp.start_link(session_id: "test-uuid")
    assert is_pid(pid)
    GenServer.stop(pid)
  end

  test "dispatch/2 sends a notification through the existing pubsub topic" do
    # subscribe to "cli:channel/<sid>" via Phoenix.PubSub before start_link;
    # call dispatch with a notification envelope;
    # assert_receive the broadcast
  end
end
```

- [ ] **Step 2: Implement**

The module is a thin wrapper over the existing `EsrWeb.McpController` flow + `cc_mcp_ready/<sid>` PubSub topic. `dispatch/2` broadcasts to the existing `cli:channel/<sid>` topic that cc_mcp subscribes to. `subscribe/3` adds to the PubSub topic. `start_link/1` is a tiny GenServer that holds session_id + pubsub topic state.

- [ ] **Step 3-5: Verify tests + commit**

### Task 2.2: claude_code manifest update

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml`

- [ ] **Step 1: Add `channels:` block**

```yaml
channels:
  - name: mcp_http
    module: Esr.Plugins.ClaudeCode.Channels.McpHttp
    config_schema:
      type: object
      properties:
        port: { type: integer }
```

- [ ] **Step 2: Smoke test — esrd boots, registry has the channel**

```bash
cd runtime && mix run -e '
{:ok, _} = Application.ensure_all_started(:esr)
{:ok, mod} = Esr.Channel.Registry.lookup("claude_code.mcp_http")
IO.puts(inspect(mod))
'
```

Expected: `Esr.Plugins.ClaudeCode.Channels.McpHttp`

- [ ] **Step 3: Commit + Phase 2 PR**

---

## Phase 3 — feishu chat Channel

**Goal:** Extract channel-shaped half (inbound dispatch + outbound emit) from `Esr.Entity.FeishuChatProxy`. Rename module `Esr.Entity.FeishuChatProxy` → `Esr.Plugins.Feishu.FeishuChatProxy` to align with file path. Register in feishu's plugin manifest.

**PR:** `feat/sessiontemplate-phase-3-feishu-channel` → `dev`. Estimate ~500 LOC + ~200 LOC tests.

### Task 3.1: Module rename

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — `defmodule` line + `@moduledoc`
- Find every caller via `grep -rn 'Esr.Entity.FeishuChatProxy' runtime/`. Update each to `Esr.Plugins.Feishu.FeishuChatProxy`.
- Update `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs` test module name.

- [ ] **Step 1: Rename**

```bash
sed -i '' 's/Esr.Entity.FeishuChatProxy/Esr.Plugins.Feishu.FeishuChatProxy/g' \
  runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex \
  $(grep -rln 'Esr.Entity.FeishuChatProxy' runtime/)
```

(macOS sed; Linux variant: drop the `''` after `-i`.)

- [ ] **Step 2: Compile + run feishu test suite**

```bash
cd runtime && mix compile && mix test test/esr/plugins/feishu/
```

Expected: green.

- [ ] **Step 3: Commit (rename only, no behavior change)**

### Task 3.2: Extract `Esr.Plugins.Feishu.Channels.ChatProxy`

The existing FCP module does both "channel" things (inbound from FAA, outbound reply emit) AND "agent-router" things (mention parser, primary routing). Extract only the channel half.

**Files:**
- Create: `runtime/lib/esr/plugins/feishu/channels/chat_proxy.ex`
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — calls into the new Channel for inbound/outbound; keeps router half
- Test: `runtime/test/esr/plugins/feishu/channels/chat_proxy_test.exs`

- [ ] **Step 1: Failing test**
- [ ] **Step 2: Move channel-shaped functions out**

`handle_info(:feishu_inbound, ...)` extracts; `emit_to_feishu_app_proxy/2` extracts. Both move into the new module under the `Esr.Channel` behaviour.

- [ ] **Step 3-5: Verify + commit**

### Task 3.3: feishu manifest update

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`

- [ ] Add `channels:` block with `chat_proxy` entry. Smoke test as in Task 2.2.

- [ ] Commit + Phase 3 PR.

---

## Phase 4 — Bundle infrastructure + first bundle (scenarios 27, 29)

**Goal:** Ship Bundle/SessionTemplate registration path end-to-end. Ship `runtime/lib/esr/bundles/feishu-cc/` (the first bundle). Ship e2e scenarios 27 (missing-dependency loud-fail) and 29 (external-path bundle install).

**PR:** `feat/sessiontemplate-phase-4-bundle-infra-plus-feishu-cc` → `dev`. Estimate ~700 LOC + ~300 LOC tests.

### Task 4.1: `Esr.Bundle.Manifest` parser

(Standard parser-with-tests pattern; mirror `Esr.Plugin.Manifest`.)

### Task 4.2: `Esr.SessionTemplate.Parser` + `FlowNodeRegistry`

Built-in flow nodes registered at boot: `Esr.Entity.Agent.MentionParser`, the `<route_to_agent>` resolver. Parser walks `flow.inbound` + `flow.outbound`; references resolve at parse time (loud-fail on unknown).

### Task 4.3: `Esr.Bundle.Loader` + `Esr.Bundle.Registry` + `Esr.SessionTemplate.Registry`

Loader walks `runtime/lib/esr/bundles/*/`, parses each bundle's `manifest.yaml` + `template.yaml`, validates dependencies, registers in two ETS tables (Bundle.Registry holds metadata; SessionTemplate.Registry holds the parsed template body keyed by name).

When a plugin enables, re-walk all bundles whose `dependencies.plugins` includes the newly enabled plugin; attempt template registration if previously skipped.

### Task 4.4: First bundle — `runtime/lib/esr/bundles/feishu-cc/`

Create the dir + the two yaml files. Content per spec §5.3.

### Task 4.5: `/plugin:install` recognizes bundles

Modify `runtime/lib/esr/commands/plugin/install.ex`. After copying source dir, check whether the dir contains `template.yaml`:
- Yes → bundle path: validate manifest + parse template + dependency check + register
- No → existing plugin path

### Task 4.6: e2e scenario 27 — missing-dependency template loud-fail

**File:** `tests/e2e/scenarios/27_template_dependency_unmet.sh`

Bash script:
1. Install only feishu plugin (skip claude_code)
2. Install feishu-cc bundle
3. Tail esrd log; assert `Logger.warning` mentions `claude_code` as missing dep
4. Try `/session:new template=feishu-cc name=foo` → assert structured error `template_dependency_unmet`
5. Enable claude_code plugin
6. Re-try `/session:new template=feishu-cc name=foo` → succeeds

### Task 4.7: e2e scenario 29 — external-path bundle install

**File:** `tests/e2e/scenarios/29_external_bundle_install.sh`

1. cp `runtime/lib/esr/bundles/feishu-cc/` to `/tmp/external_bundle/` + rename it `external-bundle/`
2. Both feishu + claude_code plugins enabled
3. `esr-dev exec /plugin:install --path=/tmp/external_bundle`
4. `esr-dev exec /plugin:enable external_bundle`
5. Assert `SessionTemplate.Registry` has the template
6. `/session:new template=feishu-cc name=foo` → succeeds (note: bundle name = `external_bundle` but template name inside is `feishu-cc`)
7. `/plugin:disable external_bundle` → assert template gone from registry
8. Existing session foo still works (frozen template)

### Task 4.8: Open Phase 4 PR

---

## Phase 5 — `/session:new` cutover (scenarios 24, 26)

**Goal:** `/session:new` reads template + instantiates session via SessionTemplate. The pipeline driver switches from agents.yaml-derived `agent_def` to template-derived `agent_def` (the spawn logic in `Esr.Session.AgentSpawner` is already YAML-driven via the agent_def map; what changes is the SOURCE of that map). **Hardcut on the source switch** — once Phase 5 lands, no path reads agents.yaml for session-creation wiring; ESR is pre-production, no compat shim.

(Reviewer correction: the existing pipeline isn't "hard-coded Elixir" — it's already a generic walker. Phase 5 swaps inputs, doesn't rewrite the walker.)

**PR:** `feat/sessiontemplate-phase-5-session-new-cutover` → `dev`. Estimate ~500 LOC + ~200 LOC tests + 2 e2e scenarios.

### Task 5.1: Default template selection

Add `Esr.Session.DefaultTemplate` module reading `default_template` from `plugins.yaml > config.session.default_template`. If unset and exactly one template registered, auto-elect that as default (boot-time write to plugins.yaml).

### Task 5.2: Rewrite `/session:new` to template-driven

Modify `Esr.Commands.Session.New`:
- Accept `template=<name>` arg
- Resolve template (explicit, or default)
- Build `agent_def` map from template's `channels:` + `agents:` + `flow:` blocks (replaces the agents.yaml-derived agent_def lookup at `runtime/lib/esr/session/agent_spawner.ex:137`)
- Channels instantiated under per-session AgentSupervisor as new children alongside CC + PTY
- `Esr.Session.AgentSpawner.do_create/1` and pipeline walker (`agent_spawner.ex:262-290`) **stay unchanged** — only the agent_def *source* swaps from `Esr.Entity.Agent.Registry.agent_def/1` to `Esr.SessionTemplate.Registry.materialize/2`.

**Hardcut on the source switch:** delete the `Esr.Entity.Agent.Registry.agent_def/1` lookup from `agent_spawner.ex:137`. The spawn walker stays.

**Note on `Esr.Plugins.Feishu.FeishuChatProxy`:** the FCP module's *channel half* is already extracted in Phase 3; Phase 5 just wires the new Channel impl as a per-session child. The FCP module's *router half* (mention parser dispatch, primary-agent routing) stays under the same module name — it's invoked by the template's `flow.inbound[].pipeline:` declarations, not removed.

### Task 5.3: Operator default-template UX

`/plugin:set plugin=session key=default_template value=feishu-cc` works without esrd restart.

### Task 5.4: e2e scenario 24 — template-instantiated session, end-to-end

Same flow as scenario 22 (existing) but driven through template instantiation, not hard-coded wiring. Must assert: session boots, inbound text routes to CC, CC reply lands in chat.

### Task 5.5: e2e scenario 26 — operator template override

Drop a custom template at `~/.esrd-<inst>/<inst>/session_templates/foo.yaml`; `/plugin:reload session_templates`; `/session:new template=foo name=baz` works.

### Task 5.6: Open Phase 5 PR

---

## Phase 6 — agents.yaml dissolution (13 consumers)

**Goal:** Delete `agents.yaml`. Move agent type definitions into plugin manifest `agent_kinds:` block. Hardcut.

**Note (per reviewer Open Q B):** the plan's "13 consumers" count is the worst case. By the time this Phase starts, Phase 5 already migrated `commands/session/new.ex` and `session/agent_spawner.ex` (their agents.yaml reads moved to template-driven), so this Phase effectively touches **≤11** files.

**PR:** `feat/sessiontemplate-phase-6-agents-yaml-dissolve` → `dev`. Estimate ~800 LOC + ~300 LOC tests.

### Task 6.0: Locate the agents.yaml on-disk seed

Reviewer Open Q C: plan says "rm `runtime/priv/agents.yaml*` (or wherever the seed lives)" — the seed location wasn't confirmed. Before the dissolution work begins:

```bash
find runtime -name 'agents*.yaml' -o -name 'agents.yaml*' 2>&1 | sort
find runtime -path '*priv*' -name '*agent*' 2>&1
grep -rn '"agents.yaml"\|/agents\.yaml\|@agents_yaml' runtime/lib/ | head -20
```

Document every match. The `application.ex:379` comment said "load from `<runtime_home>/agents.yaml`" — runtime_home is `~/.esrd-<inst>/<inst>/`, so the seed is **operator-environment-specific**, not in `runtime/priv/`. The `priv/agents.yaml*` rm in Task 6.6 likely doesn't apply (no priv copy exists) — instead `tools/wipe-esrd-home.sh` and any first-run seed code are the targets.

Output of Task 6.0: a definitive list of every file/code-path that creates, reads, or copies `agents.yaml`. Used by Task 6.6's deletion plan.

### Task 6.1: Add `agent_kinds:` block parsing to plugin manifest

(Mirror Phase 1's `channels:` block; same pattern.)

### Task 6.2: Migrate `extract_handler_modules/1` (application.ex)

Read agent_kinds from plugin registry; aggregate `handler_module` field across all enabled plugins.

### Task 6.3: Drop one FragmentMerger caller

Reviewer correction: `Esr.Yaml.FragmentMerger` is **generic** (per its moduledoc:
"agents.yaml / slash-routes.yaml / capabilities.yaml shape"). It's used by
`SlashRoute.FileLoader` + `Capability.FileLoader` too — those uses stay.
Phase 6's job here is just to **delete `Esr.Entity.Agent.Registry`'s
`merge_keyed/2` call site** (since the Registry itself goes away).
Merger module retained.

If a `~/.esrd-<inst>/<inst>/agent_kinds/<name>.yaml` operator override
is wanted post-dissolution, that's its own Task (separate phase or skip
v1; YAGNI for now since plugin manifest already supports per-deployment
overrides).

### Task 6.4: Per-consumer migration (8 sub-tasks)

Reviewer correction: bundling 8 file migrations into one task makes the PR
500+ LOC mega-change with hard review. Each consumer gets its own sub-task
+ its own commit. **Note:** Phase 5 already touched `commands/session/new.ex`
and `session/agent_spawner.ex` — by the time Phase 6 starts, the agents.yaml
references in those two files should already be removed, so this list
effectively shrinks to 11 (or fewer).

- [ ] **6.4.1**: `runtime/lib/esr/interface/spawner.ex` — read agent_kinds from plugin registry
- [ ] **6.4.2**: `runtime/lib/esr/interface/snapshot_registry.ex` — same source change
- [ ] **6.4.3**: `runtime/lib/esr/commands/workspace/remove.ex` — workspace deletion checks read plugin agent_kinds + active instances
- [ ] **6.4.4**: `runtime/lib/esr/commands/plugin/agent_types.ex` — drop agents.yaml fallback (already partially uses plugin registry post-PR-263)
- [ ] **6.4.5**: `runtime/lib/esr/resource/capability.ex` — `capabilities_required` source moves to plugin manifest agent_kinds[].capabilities_required (cap-resolution semantics preserved per Task 6.5 acceptance test)
- [ ] **6.4.6**: `runtime/lib/esr/session/router.ex` — rename `:agents_yaml_reloaded` event → `:agent_kinds_reloaded`; re-source from plugin manifest reload
- [ ] **6.4.7**: `runtime/lib/esr/plugins/claude_code/cc_process.ex` — moduledoc reference deleted (no logic change)
- [ ] **6.4.8**: `runtime/lib/esr/plugins/claude_code/manifest.yaml` — moduledoc reference deleted (no logic change)

Each sub-task: edit → run targeted tests → commit. The PR ends up with 8
small commits + the cap-resolution snapshot test (Task 6.5) as a 9th.

### Task 6.5: Cap-source migration acceptance test

Snapshot test:
1. Pre-Phase-6 baseline: spawn a representative session, capture resolved cap set
2. Post-Phase-6: same spawn, capture resolved cap set
3. Assert the two are byte-identical

### Task 6.6: Delete agents.yaml file + on-disk seed

`rm runtime/priv/agents.yaml*` (or wherever the seed lives). Update any docs that reference it.

### Task 6.7: Verify zero hits

```bash
git grep -l agents.yaml runtime/lib/
```

Expected: empty output (modulo moduledoc historical notes).

### Task 6.8: Open Phase 6 PR

---

## Phase 7 — Multi-session-per-instance (scenario 25)

**Goal:** One `Instance` registers in multiple Sessions; reply routing carries incoming session context.

**Hard dependency:** yaml-v2 spec must have merged (per-instance JSON file split). Otherwise this Phase stalls.

**PR:** `feat/sessiontemplate-phase-7-multi-session-per-instance` → `dev`. Estimate ~250 LOC + ~150 LOC tests + 1 e2e scenario.

### Task 7.0: Verify yaml-v2 prerequisite

- [ ] **Step 1: Confirm `runtime/priv/schemas/agent_instance.v1.json` is gone or schema-bumped**

```bash
test -f runtime/priv/schemas/agent_instance.v2.json || echo "STALL: yaml-v2 not merged yet"
```

If stalled, halt this phase. Do not proceed with workarounds.

### Task 7.1: Bump schema v1 → v2

`agent_instance.v2.json`: `session_id` (singular, required) → `session_ids` (array of UUIDs, min length 1, all UUIDs unique).

### Task 7.2: One-shot migration script

`mix esr.migrate_agent_instances_v1_to_v2`. Walks every `~/.esrd-<inst>/<inst>/sessions/*/agents/*.json`; if `session_id` field present, rewrite as `session_ids: [<old_value>]`. Idempotent. Runs at boot if v1 files detected.

### Task 7.3: Update `Esr.Entity.Agent.Instance` struct

`session_id :: String.t()` → `session_ids :: [String.t()]`. Fix all callers.

### Task 7.4: Update `InstanceRegistry`

`add_instance_and_spawn/2` accepts `session_ids` list. `lookup/2` matches if `name` matches AND any of the instance's `session_ids` matches the query session_id. New API: `attach_to_session/3` adds a session to an existing instance's `session_ids` list.

### Task 7.5: Update `CCProcess` reply routing

CCProcess receives `current_session_id` per inbound (carried in the message envelope). Reply broadcast carries this session's `chat_id` so the right Feishu chat receives the reply.

### Task 7.6: cc_mcp tool catalog gains `current_session_id`

Plugin-side: when claude calls a tool, the request body carries `current_session_id`. CC's system prompt is updated (in claude_code plugin's prompt template) to reference user disambiguation.

### Task 7.7: New slash `/agent:add-session`

`/agent:add-session session=<sid> name=<n>` extends existing instance with another session. Cap: `agent.attach`.

### Task 7.8: e2e scenario 25 — multi-session-per-instance

Two sessions share one CC instance. Boss session sends "hello"; reply lands in boss chat. Junior session sends "what about Y?"; reply lands in junior chat. Same instance UUID, two `chat_id` routings; CC tool calls carry `current_session_id`.

### Task 7.9: Open Phase 7 PR

---

## Phase 8 — Docs + scenario 28 + CI gate

**Goal:** Wrap up. concepts.md updated; auto-generated `docs/grammar/templates.md`; CI gate for bundle drift; e2e scenario 28 (two-agent-kind composition) validating the abstraction isn't CC-specific.

**PR:** `feat/sessiontemplate-phase-8-docs-and-finalize` → `dev`. Estimate ~300 LOC + ~200 LOC tests + 1 e2e scenario.

### Task 8.1: Update `docs/notes/concepts.md` rev-11

Add Bundle as a runtime-tier concept. Diagram updated. Realm vocabulary clarified: a Bundle implements one Realm.

### Task 8.2: `mix esr.gen_bundle_docs` mix task

Walks every registered bundle + its template, emits `docs/grammar/templates.md` (mirrors the unified-grammar `gen_command_docs` pattern). Includes per-bundle attribution + dependencies.

### Task 8.3: `mix esr.check_bundles` CI gate

Reads every bundle's manifest; verifies dependencies are real plugins; verifies template references real channel kinds + agent kinds.

### Task 8.4: Wire CI gate

Modify `.github/workflows/ci.yml` to add `mix esr.check_bundles` step.

### Task 8.5: e2e scenario 28 — two-agent-kind composition

Add a stub `Esr.Plugins.StubAgent.Channels.NoOp` Channel + a `runtime/lib/esr/plugins/stub_agent/manifest.yaml` declaring an `agent_kinds: [{name: stub}]` entry + a `runtime/lib/esr/bundles/stub-only/{manifest,template}.yaml`. Verify session creation works without changes to feishu or claude_code.

### Task 8.6: Update todo.md + manual-checks

Add the bundle promotion as a closeout in `docs/manual-checks/`. Update `docs/futures/todo.md` for Channel abstraction → closed by this work.

### Task 8.7: Open Phase 8 PR

---

## Acceptance — final verification

After all 8 phases land in dev:

- [ ] `git grep -l agents.yaml runtime/lib/` returns zero.
- [ ] `runtime/lib/esr/bundles/feishu-cc/{manifest,template}.yaml` exists.
- [ ] `mix esr.check_bundles` CI gate runs green.
- [ ] All 5 e2e scenarios (24, 25, 26, 27, 28, 29) pass on a fresh-install dev environment.
- [ ] `/session:new template=feishu-cc name=foo` works without explicit channel/agent wiring args.
- [ ] Operator-shipped bundle at `/tmp/external_bundle/` registers via `/plugin:install` end-to-end.
- [ ] Two sessions share one CC instance; reply routing distinct per session.
- [ ] Stub second agent kind boots with zero edits to feishu or claude_code plugin code.

---

## Self-review notes (post-write)

**Spec coverage:** Each spec section (§3 layers, §4 decisions, §5 concrete shapes, §6 phases, §6.1 agents.yaml consumers, §10 acceptance, §10.1 e2e) maps to phases as follows:
- §3 5-layer split → Phases 1, 4 (the new layers themselves)
- §4 decisions → architecture of Phases 1-7
- §5.1 Channel behaviour → Phase 1
- §5.2 Channel kind discovery → Phase 1, 2, 3
- §5.3 Bundle layout → Phase 4
- §5.4 Default template selection → Phase 5
- §5.5 Install lifecycle → Phase 4
- §5.6 Storage → Phase 7 (hard-depends on yaml-v2)
- §6.1 13 consumers → Phase 6 (each task)
- §10 acceptance → §"Acceptance — final verification" above
- §10.1 e2e scenarios → Phase 4 (27, 29), Phase 5 (24, 26), Phase 7 (25), Phase 8 (28)

**Placeholder scan:** No "TBD"/"TODO"/"add appropriate handling". Each phase has bite-sized tasks; long phases (3, 6) have explicit per-task structure but reuse the canary pattern from the unified-grammar plan.

**Type consistency:** `Esr.Channel` callbacks, `Esr.Bundle.Manifest`, `Esr.SessionTemplate.Parser`, `Esr.Bundle.Registry`, `Esr.SessionTemplate.Registry`, `Esr.Channel.Registry` all named consistently. Module rename (`Esr.Entity.FeishuChatProxy` → `Esr.Plugins.Feishu.FeishuChatProxy`) is one isolated transform in Phase 3.

**Hardcut audit (per user directive):** Phase 6 deletes agents.yaml outright (no v1/v2 dual-read). Phase 7 ships v2 schema + one-shot migration (no on-the-fly fallback). Phase 5 deletes the existing hard-coded session pipeline (no parallel-paths). All consistent with "no v2/legacy/translation layer" rule.
