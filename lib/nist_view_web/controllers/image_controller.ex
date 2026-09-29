defmodule NistViewWeb.ImageController do
  @moduledoc """
  Serves images rendered by the viewer from `NistView.ImageStore`.

  `no-store` keeps the browser from writing biometric images to its disk
  cache.
  """

  use NistViewWeb, :controller

  alias NistView.ImageStore

  def show(conn, %{"token" => token}) do
    case ImageStore.get(token) do
      {mime, bytes} ->
        conn
        |> put_resp_content_type(mime, nil)
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, bytes)

      nil ->
        send_resp(conn, 404, "")
    end
  end
end
