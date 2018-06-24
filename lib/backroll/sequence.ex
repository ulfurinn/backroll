defmodule Backroll.Sequence do
  use GenServer
  require Logger

  defstruct [
    :id,
    :data,
    {:steps, []},
    {:step_data, %{}},
    :on_success,
    :on_failure,
    {:finished, false},
    {:awaiting, false},
    :reason,
    {:rollback, false},
    :current_step_pid,
    :current_step_ref,
  ]

  def start_link(spec) do
    GenServer.start_link(__MODULE__, [spec])
  end

  def execute(pid),
    do: GenServer.call(pid, :execute)

  def init([spec]) do
    Process.flag(:trap_exit, true)
    state = %__MODULE__{
      id: spec.id,
      data: spec.data,
      steps: spec.steps,
      step_data: spec.steps |> collect_initial_data,
      on_success: spec.on_success,
      on_failure: spec.on_failure
    }
    {:ok, state}
  end

  def handle_call(:execute, _, state) do
    state = run_next_step(state)
    if state.finished do
      {:stop, :normal, nil, state}
    else
      {:reply, self(), state}
    end
  end

  def handle_info({:ok, data}, state) do
    state = %__MODULE__{state | data: data}
            |> finish_current_step
            |> run_next_step
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:ok, data, step_data}, state) do
    state = %__MODULE__{state | data: data}
            |> finish_current_step
            |> update_current_step_data(step_data)
            |> run_next_step
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:repeat, data}, state) do
    state = %__MODULE__{state | data: data}
            |> run_next_step
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:repeat, data, step_data}, state) do
    state = %__MODULE__{state | data: data}
            |> update_current_step_data(step_data)
            |> run_next_step
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:await, data}, state) do
    state = %__MODULE__{state | data: data, awaiting: true}
            |> finish_current_step
    {:noreply, state}
  end
  def handle_info({:await, data, step_data}, state) do
    state = %__MODULE__{state | data: data, awaiting: true}
            |> finish_current_step
            |> update_current_step_data(step_data)
    {:noreply, state}
  end

  def handle_info({:signal, term}, state = %__MODULE__{step_data: step_data}) do
    step = %Backroll.Step{ref: ref, module: m} = find_next_step(state)
    sd = if :erlang.function_exported(m, :handle_signal, 2) do
      m.handle_signal(term, step_data[ref])
    else
      term
    end
    step_data = Map.put(step_data, ref, sd)
    state = %__MODULE__{state | step_data: step_data, awaiting: false} |> run_next_step
    {:noreply, state}
  end

  # if the process exits normally, we get a response message
  def handle_info({:DOWN, _, _, pid, :normal}, state) do
    {:noreply, state}
  end
  def handle_info({:DOWN, _, _, pid, {reason, _stacktrace}}, state = %__MODULE__{current_step_pid: pid, current_step_ref: ref}) do
    steps = state.steps
            |> Enum.reverse
            |> Enum.drop_while(fn step -> step.ref != ref end)
    state = %__MODULE__{state | steps: steps, reason: reason, rollback: true}
            |> run_next_step
    {:noreply, state}
  end

  defp run_next_step(state = %__MODULE__{rollback: rollback}) do
    case find_next_step(state) do
      nil ->
        case rollback do
          false -> on_success(state)
          true -> on_failure(state)
        end
        %__MODULE__{state | finished: true}
      step = %Backroll.Step{} ->
        {pid, _} = spawn_step(step, state)
        send(pid, :start)
        %__MODULE__{state | current_step_pid: pid, current_step_ref: step.ref}
    end
  end

  defp find_next_step(state = %__MODULE__{steps: steps, rollback: false}) do
    steps |> Enum.find(fn step -> ! step.finished end)
  end
  defp find_next_step(state = %__MODULE__{steps: steps, rollback: true}) do
    steps |> Enum.find(fn step -> ! step.rolled_back end)
  end

  defp spawn_step(%Backroll.Step{ref: ref, module: m}, state = %__MODULE__{data: data, step_data: step_data, reason: reason, rollback: rollback}) do
    seq = self()
    f = fn ->
      :erlang.put(:"$backroll_sequence_pid", seq)
      receive do
        :start -> nil
      end
      result = case rollback do
        false -> apply(m, :run, [data, step_data[ref]])
        true -> apply(m, :rollback, [data, step_data[ref], reason])
      end
      send(seq, result)
    end
    spawn_monitor(f)
  end

  defp on_success(%__MODULE__{on_success: nil}), do: nil
  defp on_success(%__MODULE__{on_success: f, data: d}) when is_function(f) do
    {_, ref} = spawn_monitor fn ->
      f.(d)
    end
    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end
  defp on_success(%__MODULE__{on_success: m, data: d}) when is_atom(m) do
    {_, ref} = spawn_monitor fn ->
      apply(m, :on_success, [d])
    end
    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end

  defp on_failure(%__MODULE__{on_failure: nil}, _), do: nil
  defp on_failure(%__MODULE__{on_failure: f, data: d, reason: reason}) when is_function(f) do
    {_, ref} = spawn_monitor fn ->
      f.(d, reason)
    end
    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end
  defp on_failure(%__MODULE__{on_failure: m, data: d, reason: reason}) when is_atom(m) do
    {_, ref} = spawn_monitor fn ->
      apply(m, :on_failure, [d, reason])
    end
    receive do
      {:DOWN, ^ref, _, _, _} -> nil
    end
  end

  defp finish_current_step(state = %__MODULE__{steps: steps, current_step_ref: ref, rollback: rollback}) do
    steps = steps |> Enum.map(fn step ->
      case step.ref do
        ^ref ->
          case rollback do
            false -> step |> Backroll.Step.finished
            true -> step |> Backroll.Step.rolled_back
          end
        _ ->
          step
      end
    end)
    %__MODULE__{state | steps: steps}
  end

  defp update_current_step_data(state, data) do
    step_data = state.step_data |> Map.put(state.current_step_ref, data)
    %__MODULE__{state | step_data: step_data}
  end

  defp collect_initial_data(steps) do
    steps |> Enum.reduce(%{}, fn step, acc -> Map.put(acc, step.ref, step.data) end)
  end
end
