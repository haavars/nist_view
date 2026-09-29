defmodule NistView.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Set by the desktop shell (src-tauri); absent in a plain `mix phx.server`.
    pubsub = System.get_env("ELIXIRKIT_PUBSUB")

    children = [
      NistViewWeb.Telemetry,
      {Phoenix.PubSub, name: NistView.PubSub},
      NistView.ImageStore,
      {ElixirKit.PubSub, connect: pubsub || :ignore, on_exit: fn -> System.stop() end},
      # Start to serve requests, typically the last entry
      NistViewWeb.Endpoint
    ]

    # Reports the server's URL to the shell, so it must start after the endpoint.
    children = if pubsub, do: children ++ [NistView.Desktop], else: children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NistView.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NistViewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
