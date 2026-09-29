import Config

# config/runtime.exs is executed for all environments, including during
# releases. It runs after compilation and before the system starts.
#
# The desktop shell (src-tauri) starts the server with:
#
#   * PORT=0 - the OS picks a free port; NistView.Desktop reports it back
#   * NIST_VIEW_LAUNCH_TOKEN - a per-launch secret every page must carry
#     once (see NistViewWeb.LaunchToken)
#   * PHX_SERVER=true (releases) and ELIXIRKIT_PUBSUB
if System.get_env("PHX_SERVER") do
  config :nist_view, NistViewWeb.Endpoint, server: true
end

config :nist_view, NistViewWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :nist_view, :launch_token, System.get_env("NIST_VIEW_LAUNCH_TOKEN")

if config_env() == :prod do
  # Sessions only need to live as long as this launch, so a fresh random
  # key is fine when none is given.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  config :nist_view, NistViewWeb.Endpoint,
    url: [host: "127.0.0.1", scheme: "http"],
    # Loopback only: the viewer must not be reachable from the network.
    http: [ip: {127, 0, 0, 1}],
    check_origin: ["//127.0.0.1"],
    secret_key_base: secret_key_base
end
