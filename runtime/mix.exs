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
      listeners: [Phoenix.CodeReloader]
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
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:yaml_elixir, "~> 2.11"},
      {:file_system, "~> 1.0"},
      # PR-3: `:erlexec` is the新底座 for `Esr.OSProcess`. Chosen over
      # MuonTrap because it provides native PTY support (needed for
      # `tmux -C` control-mode on macOS where the absence of a
      # controlling TTY caused flaky immediate-exit behavior) AND
      # BEAM-exit cleanup AND bidirectional stdin/stdout — all three
      # at once, which MuonTrap cannot (see the historical
      # `.claude/skills/muontrap-elixir/SKILL.md`).
      {:erlexec, "~> 2.2"},
      # Kept temporarily; `Esr.OSProcess` no longer references it but
      # the `MuonTrap` module is still used by a couple of ad-hoc
      # callsites. Slated for removal once those are audited.
      {:muontrap, "~> 1.7"},
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
      "test.e2e.os_cleanup": ["test --only os_cleanup"]
    ]
  end
end
