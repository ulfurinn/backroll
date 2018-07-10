use Mix.Config

config :ulfnet_backroll, persistence: [module: Backroll.Persistence.ETS, supervise: true, args: []]
