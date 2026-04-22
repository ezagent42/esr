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
  directive_timeout_ms: 30_000,
  # PR-2 Peer/Session refactor feature flag. When `true`, inbound Feishu
  # frames go through `Esr.Peers.FeishuAppAdapter` (per-app_id consumer).
  # When `false`, `EsrWeb.AdapterChannel.forward_legacy/2` logs + errors
  # (post-P2-16 the legacy `AdapterHub.Registry → PeerRegistry` path was
  # deleted). Default off in P2-10; flipped on in P2-14; removed entirely
  # in P2-17. Override per-process via the `ESR_USE_NEW_PEER_CHAIN` env
  # var (see `EsrWeb.AdapterChannel.new_peer_chain?/0`).
  use_new_peer_chain: true

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

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
