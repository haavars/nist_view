defmodule NistViewWeb.ViewerLiveTest do
  use NistViewWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @phantom File.read!("test/fixtures/phantom_enrol.an2")

  defp open(conn, data, name \\ "sample.an2") do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> file_input("#upload-form-true", :transaction, [
      %{name: name, content: data, type: "application/octet-stream"}
    ])
    |> render_upload(name)

    view
  end

  test "shows the drop zone before a file is opened", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#drop-zone")
    refute has_element?(view, "#records")
  end

  test "opens an uploaded file and selects its first image", %{conn: conn} do
    view = open(conn, @phantom, "phantom_enrol.an2")

    assert has_element?(view, "#file-name", "phantom_enrol.an2")
    for i <- 0..5, do: assert(has_element?(view, "#records-#{i}"))

    # Record 2 is the first with an image (the Type-10 face).
    assert has_element?(view, "#records-2[aria-current=true]")
    assert has_element?(view, "#fields [id^='fields-2-']")

    render_async(view)
    assert has_element?(view, "#viewer-image[src^='/render/']")
  end

  test "serves the rendered image without caching", %{conn: conn} do
    view = open(conn, @phantom)
    render_async(view)

    [src] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#viewer-image")
      |> LazyHTML.attribute("src")

    conn = get(conn, src)
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "selecting a record without an image shows its fields only", %{conn: conn} do
    view = open(conn, @phantom)

    view |> element("#records-0") |> render_click()

    assert has_element?(view, "#records-0[aria-current=true]")
    refute has_element?(view, "#records-2[aria-current=true]")
    refute has_element?(view, "#viewer")
    assert has_element?(view, "#fields-0-3")
  end

  test "the arrow keys move the selection", %{conn: conn} do
    view = open(conn, @phantom)

    render_keydown(view, "key", %{"key" => "ArrowDown"})
    assert has_element?(view, "#records-3[aria-current=true]")

    render_keydown(view, "key", %{"key" => "ArrowUp"})
    assert has_element?(view, "#records-2[aria-current=true]")
  end

  test "shows a record or a binary field as hex", %{conn: conn} do
    view = open(conn, @phantom)

    view |> element("#tab-hex") |> render_click()
    assert has_element?(view, "#hex-target", "Whole record")
    assert has_element?(view, "#hex-lines > div")

    view |> element("#tab-fields") |> render_click()
    view |> element("#hex-field-2-999") |> render_click()
    assert has_element?(view, "#hex-target", "Field 999")
    assert has_element?(view, "#hex-lines #hex-0", "89 50 4E 47")
  end

  test "lays out the tenprint card", %{conn: conn} do
    view = open(conn, @phantom)

    view |> element("#view-tenprint") |> render_click()
    render_async(view)

    assert has_element?(view, "#finger-1 img[src^='/render/']")
    assert has_element?(view, "#finger-15 img")
    refute has_element?(view, "button#finger-2")

    view |> element("#finger-1") |> render_click()
    assert has_element?(view, "#records-3[aria-current=true]")
  end

  test "overlays minutiae from the Type-9 record with the same IDC", %{conn: conn} do
    import NistView.NistBuilder

    type9 =
      tagged(9, [
        {2, "1"},
        {3, "0"},
        {4, "U"},
        {130, "1"},
        {131, "500"},
        {137, "1" <> us() <> "10" <> us() <> "20" <> us() <> "45" <> us() <> "1" <> us() <> "90"}
      ])

    type14 =
      tagged(14, [
        {2, "1"},
        {6, "128"},
        {7, "96"},
        {8, "1"},
        {9, "500"},
        {10, "500"},
        {11, "WSQ20"},
        {12, "8"},
        {13, "1"},
        {999, File.read!("test/fixtures/synthetic.wsq")}
      ])

    view = open(conn, transaction([{9, 1, type9}, {14, 1, type14}]))
    render_async(view)

    assert has_element?(view, "#minutiae-overlay circle")
    assert has_element?(view, "#toggle-minutiae")
  end

  test "reports where parsing stopped and keeps the records before it", %{conn: conn} do
    view = open(conn, binary_part(@phantom, 0, 5_000))

    assert has_element?(view, "#parse-error", "At byte")
    assert has_element?(view, "#records-2")
    refute has_element?(view, "#records-3")
  end

  test "closing the file returns to the drop zone", %{conn: conn} do
    view = open(conn, @phantom)

    view |> element("#close-file") |> render_click()

    assert has_element?(view, "#drop-zone")
    refute has_element?(view, "#records-0")
  end

  test "ignores malformed or out-of-range event values", %{conn: conn} do
    view = open(conn, @phantom)

    for {event, params} <- [
          {"select", %{"index" => "x"}},
          {"select", %{"index" => "999"}},
          {"select", %{"index" => "-1"}},
          {"select", %{}},
          {"hex_field", %{"number" => "1e3"}},
          {"hex_field", %{"number" => "50"}},
          {"hex_page", %{"page" => "next"}},
          {"tab", %{"tab" => "other"}},
          {"view", %{"view" => "other"}},
          {"unknown", %{}}
        ] do
      render_hook(view, event, params)
    end

    assert has_element?(view, "#records-2[aria-current=true]")
    assert has_element?(view, "#fields-panel:not(.hidden)")
  end

  test "ignores record events before a file is open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for {event, params} <- [
          {"select", %{"index" => "0"}},
          {"key", %{"key" => "ArrowDown"}},
          {"hex_field", %{"number" => "1"}},
          {"hex_record", %{}},
          {"hex_page", %{"page" => "1"}}
        ] do
      render_hook(view, event, params)
    end

    assert has_element?(view, "#drop-zone")
  end
end
