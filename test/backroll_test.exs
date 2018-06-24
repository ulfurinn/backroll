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

  defmodule ListBuilder do
    @behaviour Backroll.Step

    def run(data, element) do
      {:ok, [element | data], element}
    end

    def rollback([element|tail], element, _) do
      {:ok, tail}
    end
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
    assert {:ok, 6} = Backroll.new("test", 3)
                      |> Backroll.step(Multiplier)
                      |> run
  end

  test "a simple sequence with a parameter" do
    assert {:ok, 9} = Backroll.new("test", 3)
                      |> Backroll.step(Multiplier, 3)
                      |> run
  end

  test "a sequence with multiple steps" do
    assert {:ok, [3,2,1]} = Backroll.new("test", [])
                            |> Backroll.step(ListBuilder, 1)
                            |> Backroll.step(ListBuilder, 2)
                            |> Backroll.step(ListBuilder, 3)
                            |> run
  end

  test "rollbacks" do
    assert {:error, [], _} = Backroll.new("test", [])
                            |> Backroll.step(ListBuilder, 1)
                            |> Backroll.step(ListBuilder, 2)
                            |> Backroll.step(ListBuilder, 3)
                            |> Backroll.step(Crash, fn -> 1 = 2 end)
                            |> run
  end

  test "a simple sequence crashing with an exit" do
    assert {:error, 3, {:badmatch, _}} = Backroll.new("test", 3)
                                                 |> Backroll.step(Crash, fn -> 1 = 2 end)
                                                 |> run
  end

  test "a simple sequence with a raise" do
    assert {:error, 3, %RuntimeError{message: "hell"}} = Backroll.new("test", 3)
                                                                 |> Backroll.step(Crash, fn -> raise "hell" end)
                                                                 |> run
  end

  # helper functions

  defp supervisor do
    {:ok, pid} = Backroll.Supervisor.start()
    pid
  end

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
    after 100 ->
      flunk("The sequence did not end in time")
    end

  end
end
