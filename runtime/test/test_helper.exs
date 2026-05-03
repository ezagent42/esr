ExUnit.start(exclude: [:integration, :os_cleanup, :perf])

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
