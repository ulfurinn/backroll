defmodule Backroll.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec

    persistence = Application.get_env(:ulfnet_backroll, :persistence, [])
    persistence_spec = if persistence[:supervise] do
      [worker(persistence[:module], persistence[:args])]
    else
      []
    end

    children = persistence_spec ++ [
      worker(Backroll.Registry, []),
    ]

    opts = [strategy: :one_for_one, name: Backroll.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
