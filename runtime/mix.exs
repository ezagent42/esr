defmodule Esr.MixProject do
  use Mix.Project

  def project do
    [
      app: :esr,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      # Phase 2 PR-2.5: Elixir-native CLI escript. Built via
      # `mix escript.build`; produces a self-contained `esr` binary
      # that talks to a running esrd via the schema dump endpoint
      # (PR-2.1) and the admin queue (PR-2.3b).
      escript: [
        main_module: Esr.Cli.Main,
        name: "esr",
        path: "esr",
        app: nil
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Esr.Application, []},
      # `:erlexec` is declared here so OTP auto-starts `exec` (the
      # supervisor that owns the C++ `exec-port` program) before any
      # `Esr.OSProcess`-backed peer calls `:exec.run_link/2`.
      # PR-3: replaces the Port.open + MuonTrap wrapper path.
      extra_applications: [:logger, :runtime_tools, :erlexec]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.e2e.os_cleanup": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      # PR-22 prep, PR-23 retained: esbuild bundles assets/js/app.js
      # (xterm.js + Phoenix Channel client).
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:yaml_elixir, "~> 2.11"},
      {:file_system, "~> 1.0"},
      # `Esr.OSProcess` 底座 — native PTY support (for tmux -C) +
      # bidirectional stdin/stdout + BEAM-exit cleanup, all in one.
      # Migration history: docs/notes/erlexec-migration.md.
      {:erlexec, "~> 2.2"},
      {:elixir_uuid, "~> 1.2", hex: :uuid_utils},
      {:ex_json_schema, "~> 0.11", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"],
      # P3-12: "nightly gate" per spec §10.5 — kills an esrd BEAM subprocess
      # with SIGKILL and asserts no tmux orphans within 10 s. Excluded from
      # default `mix test` via `:os_cleanup` tag in test_helper.exs; runs
      # only when this alias (or `mix test --only os_cleanup`) is invoked.
      "test.e2e.os_cleanup": ["test --only os_cleanup"],
      # PR-24 follow-up: standard Phoenix alias so prod releases /
      # operators bundling without dev-mode watchers get a fresh,
      # minified app.js / app.css. Run via `MIX_ENV=prod mix assets.deploy`.
      "assets.deploy": ["esbuild default --minify", "phx.digest"]
    ]
  end
end
