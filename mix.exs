defmodule NistView.MixProject do
  use Mix.Project

  def project do
    [
      app: :nist_view,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # :nist_decode builds the out-of-process image decoder (NistView.Decoder).
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:nist_decode],
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {NistView.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "desktop.release": :prod]
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
      {:phoenix, "~> 1.8.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:rustler, "~> 0.38.0", runtime: false},
      {:elixirkit, github: "livebook-dev/elixirkit"}
    ]
  end

  # The release the desktop shell bundles (see src-tauri). On macOS every
  # executable in it is signed, with APPLE_SIGNING_IDENTITY or ad hoc.
  defp releases do
    [
      nist_view: [
        steps: [:assemble, &ElixirKit.Release.codesign/1],
        entitlements: Path.expand("src-tauri/App.entitlements", __DIR__)
      ]
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
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind nist_view", "esbuild nist_view"],
      "assets.deploy": [
        "tailwind nist_view --minify",
        "esbuild nist_view --minify",
        "phx.digest"
      ],
      # Run by `cargo tauri build` (src-tauri/tauri.conf.json).
      "desktop.release": [
        "compile",
        "assets.deploy",
        "release nist_view --overwrite --path src-tauri/target/rel"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test",
        "cmd --cd native/nist_codecs cargo test --release --quiet",
        "cmd --cd native/nbis_ref cargo test --release --quiet"
      ]
    ]
  end
end
