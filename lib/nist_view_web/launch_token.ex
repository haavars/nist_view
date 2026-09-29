defmodule NistViewWeb.LaunchToken do
  @moduledoc """
  Restricts the viewer to the desktop shell that launched it.

  When `:launch_token` is configured (the shell sets
  `NIST_VIEW_LAUNCH_TOKEN`, a fresh random value per launch), a request
  must either carry `?launch=<token>` or belong to a session that already
  did. The token is then removed from the URL with a redirect. Other local
  programs and web pages cannot reach the server's pages, images or
  LiveView socket without it.

  Without a configured token (development in a browser, tests) everything
  is allowed.

  Used as a plug in the browser pipeline and as a LiveView `on_mount` hook.
  """

  import Plug.Conn

  @behaviour Plug

  @session_key "launch_token_ok"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case token() do
      nil -> conn
      token -> check(conn, token)
    end
  end

  defp check(conn, token) do
    conn = fetch_query_params(conn)

    cond do
      valid?(conn.query_params["launch"], token) ->
        query = conn.query_params |> Map.delete("launch") |> URI.encode_query()
        path = if query == "", do: conn.request_path, else: conn.request_path <> "?" <> query

        conn
        |> put_session(@session_key, true)
        |> Phoenix.Controller.redirect(to: path)
        |> halt()

      get_session(conn, @session_key) == true ->
        conn

      true ->
        conn |> send_resp(403, "Forbidden") |> halt()
    end
  end

  @doc false
  def on_mount(:default, _params, session, socket) do
    if token() == nil or session[@session_key] == true,
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp token, do: Application.get_env(:nist_view, :launch_token)

  defp valid?(given, token) when is_binary(given), do: Plug.Crypto.secure_compare(given, token)
  defp valid?(_given, _token), do: false
end
