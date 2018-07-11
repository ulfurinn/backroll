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
    {:signals, []},
    :persistence_mod,
  ]

  def start_link(spec_or_continuation) do
    GenServer.start_link(__MODULE__, [spec_or_continuation])
  end

  def execute(pid),
    do: GenServer.call(pid, :execute)

  def signal(pid, term, timeout \\ :infinity),
    do: GenServer.call(pid, {:signal, term}, timeout)

  def init([{:new, spec}]) do
    Process.flag(:trap_exit, true)
    state = %__MODULE__{
      id: spec.id,
      data: spec.data,
      steps: spec.steps,
      step_data: spec.steps |> collect_initial_data,
      on_success: spec.on_success,
      on_failure: spec.on_failure,
      persistence_mod: spec.persistence_mod,
    }
    {:ok, state}
  end
  def init([{:continuation, spec}]) do
    Process.flag(:trap_exit, true)
    state = %__MODULE__{} |> Map.merge(spec)
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
  def handle_call({:signal, term}, _, state = %__MODULE__{awaiting: true}) do
    state = term
            |> apply_signal(state)
            |> persist
    {:reply, nil, state}
  end
  def handle_call({:signal, term}, _, state = %__MODULE__{signals: signals}) do
    state = %__MODULE__{state | signals: signals ++ [term]}
            |> persist
    {:reply, nil, state}
  end

  def handle_info({:"$backroll", :step_reply, {:ok, data}}, state) do
    state = %__MODULE__{state | data: data}
            |> finish_current_step
            |> run_next_step
            |> persist
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:"$backroll", :step_reply, {:ok, data, step_data}}, state) do
    state = %__MODULE__{state | data: data}
            |> finish_current_step
            |> update_current_step_data(step_data)
            |> run_next_step
            |> persist
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:"$backroll", :step_reply, {:repeat, data}}, state) do
    state = %__MODULE__{state | data: data}
            |> run_next_step
            |> persist
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:"$backroll", :step_reply, {:repeat, data, step_data}}, state) do
    state = %__MODULE__{state | data: data}
            |> update_current_step_data(step_data)
            |> run_next_step
            |> persist
    if state.finished do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
  def handle_info({:"$backroll", :step_reply, {:await, data}}, state) do
    state = %__MODULE__{state | data: data, awaiting: true}
            |> finish_current_step
            |> apply_queued_signals
            |> persist
    {:noreply, state}
  end
  def handle_info({:"$backroll", :step_reply, {:await, data, step_data}}, state) do
    state = %__MODULE__{state | data: data, awaiting: true}
            |> finish_current_step
            |> update_current_step_data(step_data)
            |> apply_queued_signals
            |> persist
    {:noreply, state}
  end
  def handle_info({:"$backroll", :step_reply, {{:delay, millis}, data}}, state) do
    state = %__MODULE__{state | data: data}
            |> finish_current_step
            |> persist
    :erlang.send_after(millis, self(), {:"$backroll", :delay_wakeup})
    {:noreply, state}
  end
  def handle_info({:"$backroll", :step_reply, {{:delay, millis}, data, step_data}}, state) do
    state = %__MODULE__{state | data: data}
            |> finish_current_step
            |> update_current_step_data(step_data)
            |> persist
    :erlang.send_after(millis, self(), {:"$backroll", :delay_wakeup})
    {:noreply, state}
  end

  def handle_info({:"$backroll", :delay_wakeup}, state = %__MODULE__{}) do
    state = state
            |> run_next_step
            |> persist
    {:noreply, state}
  end

  # if the process exits normally, we get a response message
  def handle_info({:DOWN, _, _, _, :normal}, state) do
    {:noreply, state}
  end
  def handle_info({:DOWN, _, _, pid, {reason, _stacktrace}}, state = %__MODULE__{current_step_pid: pid, current_step_ref: ref}) do
    steps = state.steps
            |> Enum.reverse
            |> Enum.drop_while(fn step -> step.ref != ref end)
    state = %__MODULE__{state | steps: steps, reason: reason, rollback: true}
            |> run_next_step
            |> persist
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.error("unexpected message #{inspect message}")
    {:noreply, state}
  end

  defp apply_signal(signal, state = %__MODULE__{step_data: step_data}) do
    %Backroll.Step{ref: ref, module: m} = find_next_step(state)
    sd = if function_exported?(m, :handle_signal, 2) do
      m.handle_signal(signal, step_data[ref])
    else
      signal
    end
    step_data = Map.put(step_data, ref, sd)
    %__MODULE__{state | step_data: step_data, awaiting: false}
    |> run_next_step
  end

  defp apply_queued_signals(state = %__MODULE__{signals: []}),
    do: state
  defp apply_queued_signals(state = %__MODULE__{signals: [signal]}) do
    state = signal |> apply_signal(state)
    %__MODULE__{state | signals: []}
  end

  defp run_next_step(state = %__MODULE__{finished: true}), do: state
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

  defp find_next_step(%__MODULE__{steps: steps, rollback: false}) do
    steps |> Enum.find(fn step -> ! step.finished end)
  end
  defp find_next_step(%__MODULE__{steps: steps, rollback: true}) do
    steps |> Enum.find(fn step -> ! step.rolled_back end)
  end

  defp spawn_step(%Backroll.Step{ref: ref, module: m}, %__MODULE__{data: data, step_data: step_data, reason: reason, rollback: rollback}) do
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
      send(seq, {:"$backroll", :step_reply, result})
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

  defp on_failure(%__MODULE__{on_failure: nil}), do: nil
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

  defp persist(state = %__MODULE__{persistence_mod: nil}), do: state
  defp persist(state = %__MODULE__{persistence_mod: m}) do
    m.save(state.id, remove_transient_fields(state))
    state
  end

  defp remove_transient_fields(state = %__MODULE__{}) do
    %__MODULE__{
      state |
      on_success: filter_callback(state.on_success),
      on_failure: filter_callback(state.on_failure),
      current_step_ref: nil,
      current_step_pid: nil,
    }
  end

  defp filter_callback(f) when is_function(f), do: nil
  defp filter_callback(x), do: x
end
