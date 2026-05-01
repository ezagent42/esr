# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :esr,
  generators: [timestamp_type: :utc_datetime],
  telemetry_buffer_retention_minutes: 15,
  handler_call_timeout_ms: 5_000,
  directive_timeout_ms: 30_000

# Configures the endpoint
config :esr, EsrWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: EsrWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EsrWeb.PubSub,
  live_view: [signing_salt: "5RJhXWZR"]

# PR-22: esbuild bundles assets/js/app.js → priv/static/assets/app.js
# (xterm.js + Phoenix LiveView client). Run via `mix esbuild default`
# at build time; in dev with `mix phx.server` the watcher rebuilds
# automatically (configured in dev.exs).
config :esbuild,
  version: "0.21.5",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --loader:.css=css),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
