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
    {:reason, :normal},
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
    state = state
            |> apply_signal(term)
            |> persist
    {:reply, nil, state}
  end
  def handle_call({:signal, term}, _, state = %__MODULE__{signals: signals}) do
    state = %__MODULE__{state | signals: signals ++ [term]}
            |> persist
    {:reply, nil, state}
  end


  def handle_info({:"$backroll", :step_reply, reply}, state) do
    state = handle_step_reply(reply, state)
    if state.finished do
      {:stop, state.reason, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:"$backroll", :delay_wakeup}, state = %__MODULE__{}) do
    state = state
            |> run_next_step
            |> persist
    {:noreply, state}
  end

  # if the process exits normally, we get a response message
  def handle_info({:DOWN, _, _, pid, :normal}, state = %__MODULE__{current_step_pid: pid}) do
    {:noreply, %__MODULE__{state | current_step_pid: nil, current_step_ref: nil}}
  end
  def handle_info({:DOWN, _, _, pid, {reason, _stacktrace}}, state = %__MODULE__{current_step_pid: pid}) do
    state = state
            |> reverse_on_crash(reason)
            |> run_next_step
            |> persist
    {:noreply, state}
  end
  def handle_info({:DOWN, _, _, _, _}, state),
    do: {:noreply, state}

  def handle_info(message, state) do
    Logger.error("unexpected message #{inspect message}")
    {:noreply, state}
  end

  def terminate(_, %__MODULE__{current_step_pid: nil}) do
    nil
  end
  def terminate(_, state = %__MODULE__{current_step_pid: pid}) do
    case wait_for_down(pid) do
      :normal ->
        process_last_message(state)
      reason ->
        state
        |> reverse_on_crash(reason)
        |> persist
    end
  end

  defp handle_step_reply(reply, state)
  defp handle_step_reply({action, data}, state) do
    state
    |> update_data(data)
    |> handle_step_reply_action(action)
    |> persist
  end
  defp handle_step_reply({action, data, step_data}, state) do
    state
    |> update_data(data)
    |> update_current_step_data(step_data)
    |> handle_step_reply_action(action)
    |> persist
  end

  defp handle_step_reply_action(state, :ok) do
    state
    |> finish_current_step
    |> run_next_step
  end

  defp handle_step_reply_action(state, :repeat) do
    state
    |> run_next_step
  end

  defp handle_step_reply_action(state, :await) do
    %__MODULE__{state | awaiting: true}
    |> finish_current_step
    |> apply_queued_signals
  end

  defp handle_step_reply_action(state, {:delay, millis}) do
    :erlang.send_after(millis, self(), {:"$backroll", :delay_wakeup})
    state
    |> finish_current_step
  end

  defp wait_for_down(pid) do
    receive do
      {:DOWN, _, _, ^pid, reason} ->
        case reason do
          {reason, _stacktrace} ->
            reason
          reason ->
            reason
        end
    end
  end

  defp process_last_message(state) do
    receive do
      {:"$backroll", :step_reply, reply} ->
        {action, state} = case reply do
          {action, data} ->
            state = state |> update_data(data)
            {action, state}
          {action, data, step_data} ->
            state = state |> update_data(data) |> update_current_step_data(step_data)
            {action, state}
        end
        state = case action do
          :ok ->
            state |> finish_current_step
          :repeat ->
            state
          {:delay, _} ->
            state
          :await ->
            case state.signals do
              [signal] ->
                state |> finish_current_step |> apply_signal_no_run(signal)
              _ ->
                state |> finish_current_step
            end
        end
        state |> persist
    end
  end

  defp reverse_on_crash(state = %__MODULE__{steps: steps, current_step_ref: ref}, reason) do
    steps = steps
            |> Enum.reverse
            |> Enum.drop_while(fn step -> step.ref != ref end)
    %__MODULE__{state | steps: steps, reason: reason, rollback: true}
  end

  defp apply_signal_no_run(state = %__MODULE__{step_data: step_data}, signal) do
    %Backroll.Step{ref: ref, module: m} = find_next_step(state)
    sd = if function_exported?(m, :handle_signal, 2) do
      m.handle_signal(signal, step_data[ref])
    else
      signal
    end
    step_data = Map.put(step_data, ref, sd)
    %__MODULE__{state | step_data: step_data, awaiting: false}
  end
  defp apply_signal(state = %__MODULE__{}, signal) do
    apply_signal_no_run(state, signal)
    |> run_next_step
  end

  defp apply_queued_signals(state = %__MODULE__{signals: []}),
    do: state
  defp apply_queued_signals(state = %__MODULE__{signals: [signal]}) do
    state = state |> apply_signal(signal)
    %__MODULE__{state | signals: []}
  end

  defp run_next_step(state = %__MODULE__{finished: true}), do: state
  defp run_next_step(state = %__MODULE__{awaiting: true}), do: state
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
    %__MODULE__{state | steps: steps, current_step_ref: nil, current_step_pid: nil}
  end

  defp update_data(state, data),
    do: %__MODULE__{state | data: data}

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
