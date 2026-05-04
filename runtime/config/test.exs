import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :esr, EsrWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rVk2BwGPJcnineSZ/8OdIUxzchpSsJgb+Wec0X0rGKmZJacuU8flXK9NGoTkiAPK",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Don't auto-bootstrap artifacts from ~/.esrd in test runs — each test
# case sets up the exact registry state it expects.
config :esr, bootstrap_artifacts: false
config :esr, restore_on_start: false

# Track 0 Task 0.5 (plugin work). Tests must not implicitly enable any
# plugin — each test sets up the exact registry state it needs.
# Without this override, runtime.exs's Phase-1 fallback would attempt
# to load `[:feishu, :claude_code, :voice]`, which would noisy-log and
# (post-extraction) actually start plugin supervisors mid-test.
config :esr, :enabled_plugins, []

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
