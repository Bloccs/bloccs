defmodule PriceWatch.Repo do
  use Ecto.Repo,
    otp_app: :price_watch,
    adapter: Ecto.Adapters.SQLite3
end
