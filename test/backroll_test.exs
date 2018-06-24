defmodule BackrollTest do
  use ExUnit.Case

  # helper step modules

  defmodule Multiplier do
    @behaviour Backroll.Step

    def run(data, nil) do
      {:ok, data * 2}
    end
    def run(data, mult) do
      {:ok, data * mult}
    end
    def rollback(data, _, _reason) do
      {:ok, data}
    end
  end

  defmodule Repeater do
    @behaviour

    def run(data, step_data = {element, count}) do
      data = [element | data]
      if length(data) < count do
        {:repeat, data, step_data}
      else
        {:ok, data, step_data}
      end
    end
    def rollback(data, _, _), do: {:ok, data}
  end

  defmodule ListBuilder do
    @behaviour Backroll.Step

    def run(data, element) do
      {:ok, [element | data], element}
    end
    def rollback([element|tail], element, _) do
      {:ok, tail}
    end
  end

  defmodule AwaitSender do
    @behaviour Backroll.Step

    def run(data, a) do
      spawn fn ->
        Process.sleep(100)
        Backroll.signal("test", a)
      end
      {:await, data}
    end
    def rollback(data, _, _), do: {:ok, data}
  end

  defmodule AwaitReceiver do
    @behaviour Backroll.Step

    def handle_signal(signal, step_data) do
      %{first: signal, second: step_data}
    end

    def run(data, step_data) do
      {:ok, Map.merge(data, step_data)}
    end
    def rollback(data, _, _), do: {:ok, data}
  end

  defmodule Crash do
    @behaviour Backroll.Step

    def run(_, f) do
      f.()
    end
    def rollback(data, _, reason) do
      {:ok, data, reason}
    end
  end

  # actual tests

  test "a simple sequence" do
    assert {:ok, 6} = new(3)
                      |> step(Multiplier)
                      |> run
  end

  test "a simple sequence with a parameter" do
    assert {:ok, 9} = new(3)
                      |> step(Multiplier, 3)
                      |> run
  end

  test "a sequence with a repeating step" do
    assert {:ok, [1, 1, 1]} = new([])
                              |> step(Repeater, {1, 3})
                              |> run
  end

  test "a sequence with multiple steps" do
    assert {:ok, [3,2,1]} = new([])
                            |> step(ListBuilder, 1)
                            |> step(ListBuilder, 2)
                            |> step(ListBuilder, 3)
                            |> run
  end

  test "rollbacks" do
    assert {:error, [], _} = new([])
                            |> step(ListBuilder, 1)
                            |> step(ListBuilder, 2)
                            |> step(ListBuilder, 3)
                            |> step(Crash, fn -> 1 = 2 end)
                            |> run
  end

  test "a simple sequence crashing with an exit" do
    assert {:error, 3, {:badmatch, _}} = new(3)
                                         |> step(Crash, fn -> 1 = 2 end)
                                         |> run
  end

  test "a simple sequence with a raise" do
    assert {:error, 3, %RuntimeError{message: "hell"}} = new(3)
                                                         |> step(Crash, fn -> raise "hell" end)
                                                         |> run
  end

  test "a sequence with an await step" do
    assert {:ok, %{first: 5, second: 2}} = new(%{})
                      |> step(AwaitSender, 5)
                      |> step(AwaitReceiver, 2)
                      |> run
  end

  # helper functions

  defp supervisor do
    {:ok, pid} = Backroll.Supervisor.start()
    pid
  end

  defp new(initial), do: Backroll.new("test", initial)
  defp step(state, step), do: Backroll.step(state, step)
  defp step(state, step, data), do: Backroll.step(state, step, data)

  defp run(backroll) do
    test = self()
    backroll
    |> Backroll.on_success(fn data -> send(test, {:ok, data}) end)
    |> Backroll.on_failure(fn data, reason -> send(test, {:error, data, reason}) end)
    |> Backroll.start(supervisor())
    receive_response()
  end

  defp receive_response do
    receive do
      x ->
        x
    after 1000 ->
      flunk("The sequence did not end in time")
    end
  end
  defp cleanup_registry, do: cleanup_registry(1000)
  defp cleanup_registry(n) when n < 0, do: flunk("the registry took too long to reset")
  defp cleanup_registry(n) do
    case Backroll.Registry.lookup("test") do
      nil -> nil
      _ ->
        Process.sleep(10)
        cleanup_registry(n - 10)
    end
  end

  setup _ do
    on_exit &cleanup_registry/0
    :ok
  end
end
