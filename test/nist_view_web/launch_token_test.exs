defmodule NistViewWeb.LaunchTokenTest do
  # Changes application config, so not async.
  use NistViewWeb.ConnCase, async: false

  setup do
    Application.put_env(:nist_view, :launch_token, "secret")
    on_exit(fn -> Application.delete_env(:nist_view, :launch_token) end)
  end

  test "refuses pages and images without the token", %{conn: conn} do
    assert conn |> get(~p"/") |> response(403)
    assert conn |> get(~p"/render/anything") |> response(403)
    assert conn |> get(~p"/?launch=wrong") |> response(403)
  end

  test "accepts the token once, then the session", %{conn: conn} do
    conn = get(conn, ~p"/?launch=secret&open=abc")
    assert redirected_to(conn) == "/?open=abc"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Open an ANSI/NIST-ITL file"
  end

  test "sends a content security policy", %{conn: conn} do
    conn = conn |> get(~p"/?launch=secret") |> recycle() |> get(~p"/")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self'"
  end
end
