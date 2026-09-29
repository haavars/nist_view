defmodule NistViewWeb.DesktopOpenTest do
  # NistView.Desktop is a named process, so not async.
  use NistViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NistView.Desktop

  @fixture Path.expand("test/fixtures/phantom_enrol.an2")

  setup do
    start_supervised!({Desktop, pubsub: false})
    :ok
  end

  test "opens a path the shell registered before the window connected", %{conn: conn} do
    :ok = Desktop.put("id1", @fixture)

    {:ok, view, _html} = live(conn, ~p"/?open=id1")

    assert has_element?(view, "#file-name", "phantom_enrol.an2")
    # A path is handed out once.
    assert Desktop.take("id1") == :pending
  end

  test "opens a path that arrives after the window connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?open=id2")
    assert has_element?(view, "#drop-zone")

    :ok = Desktop.put("id2", @fixture)

    assert render(view) =~ "phantom_enrol.an2"
    assert has_element?(view, "#records-0")
  end

  test "ignores ids nobody registered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?open=unknown")
    assert has_element?(view, "#drop-zone")
  end
end
