defmodule NistViewWeb.PageController do
  use NistViewWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
