ExUnit.start(exclude: [:integration, :os_cleanup, :perf, :real_claude])

# PR-21κ Phase 6: load the priv default slash-routes once at boot so
# Dispatcher tests (which look up kind → permission via SlashRouteRegistry
# ETS) see the production kind table. Tests that reset to an empty
# snapshot for isolation should restore from this default in their
# on_exit hook.
case Process.whereis(Esr.Resource.SlashRoute.Registry) do
  pid when is_pid(pid) ->
    priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
    if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)

  _ ->
    :ok
end

# Sidecar leak prevention. Without this, any test that spawns an
# Esr.OSProcess (which uses :exec.run_link) AND crashes the test BEAM
# uncleanly leaves the erlexec exec-port + python child alive — they
# orphan to init and accumulate. Discovered 2026-05-10 with 198 zombie
# BEAMs + 78 orphan feishu_adapter_runner processes on the dev machine.
#
# Hook strategy: register a System.at_exit/1 callback that walks every
# alive :exec OS pid via :exec.which_children/0 and stop_and_wait/2's
# them with a 2 s SIGTERM grace before SIGKILL escalation. at_exit/1
# fires for normal `:init.stop/0` shutdown AND when ExUnit decides to
# halt after test failures, so it covers the common leak path.
#
# `:exec` may not be running in unit tests that don't load the full
# Esr.Application — guard with Process.whereis. The erlexec API:
# `:exec.which_children/0` returns a flat `[ospid()]` list (verified in
# deps/erlexec/src/exec.erl:488); `:exec.stop_and_wait(ospid, ms)` sends
# SIGTERM, waits up to `ms`, then SIGKILL — exactly what we want for
# orderly child shutdown without giving any one sidecar a chance to hang
# the BEAM exit.
System.at_exit(fn _exit_status ->
  if Process.whereis(:exec) do
    try do
      for os_pid <- :exec.which_children() do
        try do
          :exec.stop_and_wait(os_pid, 2_000)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end)
