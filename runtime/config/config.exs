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
  pubsub_server: Esr.PubSub,
  live_view: [signing_salt: "5RJhXWZR"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
