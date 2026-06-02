import Config

# Build the SQLite NIF from source (the precompiled binary targets a newer
# glibc than some systems ship). Needs a C compiler + make.
config :exqlite, force_build: true

# The example's own Ecto repo, backed by a local SQLite file (zero external
# services). The file is recreated/ensured on boot.
config :price_watch, ecto_repos: [PriceWatch.Repo]

config :price_watch, PriceWatch.Repo,
  database: Path.expand("../priv/price_watch.db", __DIR__),
  pool_size: 5,
  # Quiet per-query logging so the demo output reads cleanly; flip to a level
  # like :debug to watch the real SQL go by.
  log: false

# Where the (local) stub quote API listens. The bloccs node calls this over a
# real HTTP socket via the Req backend.
config :price_watch, :api_port, 4011

# --- bloccs: select the REAL effect backends (this is the production switch) ---
config :bloccs, :effect_backends,
  http: Bloccs.Effects.HTTP.Req,
  db: Bloccs.Effects.DB.Ecto

# Point the bloccs Ecto DB adapter at our repo.
config :bloccs, Bloccs.Effects.DB.Ecto, repo: PriceWatch.Repo
