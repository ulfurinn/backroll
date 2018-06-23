defmodule Backroll.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    import Supervisor.Spec

    children = []

    opts = [strategy: :one_for_one, name: Backroll.Supervisor]
    Supervisor.start_link(children, opts)
  end
end