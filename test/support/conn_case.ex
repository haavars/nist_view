defmodule NistViewWeb.ConnCase do
  @moduledoc """
  The test case for tests that need a connection: imports
  `Phoenix.ConnTest` and the verified routes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint NistViewWeb.Endpoint

      use NistViewWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import NistViewWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
