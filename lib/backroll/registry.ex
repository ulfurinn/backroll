defmodule Backroll.Registry do
  use GenServer

  defstruct [
    {:id_to_pid, %{}},
    {:pid_to_id, %{}}
  ]

  def start_link do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def register(id, pid),
    do: GenServer.call(__MODULE__, {:register, id, pid})

  def lookup(id),
    do: GenServer.call(__MODULE__, {:lookup, id})

  def init(_) do
    {:ok, %__MODULE__{}}
  end

  def handle_call({:register, id, pid}, _, %__MODULE__{id_to_pid: id_to_pid, pid_to_id: pid_to_id}) do
    Process.monitor(pid)
    {:reply, nil, %__MODULE__{id_to_pid: Map.put(id_to_pid, id, pid), pid_to_id: Map.put(pid_to_id, pid, id)}}
  end

  def handle_call({:lookup, id}, _, state = %__MODULE__{id_to_pid: id_to_pid}) do
    {:reply, id_to_pid[id], state}
  end

  def handle_info({:DOWN, _, _, pid, _}, %__MODULE__{id_to_pid: id_to_pid, pid_to_id: pid_to_id}) do
    id = pid_to_id[pid]
    {:noreply, %__MODULE__{id_to_pid: Map.delete(id_to_pid, id), pid_to_id: Map.delete(pid_to_id, pid)}}
  end
end
