defmodule Backroll.Supervisor do
  use Supervisor

  def start() do
    {:ok, pid} = Supervisor.start_link(__MODULE__, [])
    Process.unlink(pid)
    {:ok, pid}
  end

  def start_link() do
    Supervisor.start_link(__MODULE__, [])
  end
  def start_link(name) do
    Supervisor.start_link(__MODULE__, [], name: name)
  end

  def init([]) do
    supervise([worker(Backroll.Sequence, [])], strategy: :simple_one_for_one)
  end
end
