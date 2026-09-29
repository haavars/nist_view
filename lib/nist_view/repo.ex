defmodule NistView.Repo do
  use Ecto.Repo,
    otp_app: :nist_view,
    adapter: Ecto.Adapters.Postgres
end
