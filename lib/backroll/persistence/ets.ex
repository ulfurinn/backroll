defmodule Backroll.Persistence.ETS do
  @behaviour Backroll.Persistence

  use GenServer

  def start_link,
    do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def save(id, data),
    do: GenServer.call(__MODULE__, {:save, id, data})

  def load_all do
    :ets.first(__MODULE__) |> fold_table
  end

  defp fold_table(key), do: fold_table(key, [])
  defp fold_table(:"$end_of_table", acc), do: acc
  defp fold_table(key, acc) do
    [entry] = :ets.lookup(__MODULE__, key)
    fold_table(:ets.next(__MODULE__, key), [entry | acc])
  end

  def init(_) do
    :ets.new(__MODULE__, [:set, :protected, :named_table, {:write_concurrency, true}])
    {:ok, nil}
  end

  def handle_call({:save, id, data}, _, state) do
    if data.finished do
      :ets.delete(__MODULE__, id)
    else
      :ets.insert(__MODULE__, {id, data})
    end
    {:reply, nil, state}
  end
end
