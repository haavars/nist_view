defmodule NistViewWeb.Router do
  use NistViewWeb, :router

  # Everything comes from this server. Inline styles are needed for
  # LiveView-set style attributes; there are no inline scripts.
  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self'",
           "style-src 'self' 'unsafe-inline'",
           "img-src 'self' data: blob:",
           "connect-src 'self' ws://127.0.0.1:* ws://localhost:*",
           "font-src 'self'",
           "object-src 'none'",
           "base-uri 'self'",
           "frame-ancestors 'none'",
           "form-action 'self'"
         ],
         "; "
       )

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug NistViewWeb.LaunchToken
    plug :put_root_layout, html: {NistViewWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NistViewWeb do
    pipe_through :browser

    live_session :viewer, on_mount: NistViewWeb.LaunchToken do
      live "/", ViewerLive
    end

    get "/render/:token", ImageController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", NistViewWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:nist_view, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NistViewWeb.Telemetry
    end
  end
end
