defmodule Backroll do
  @moduledoc """
  Backroll provides interruptible and rollbackable sequences of processing steps.
  """

  defstruct [
    :id,
    :data,
    {:steps, []},
    :on_success,
    :on_failure,
  ]

  def new(id, data) do
    %__MODULE__{
      id: id,
      data: data,
    }
  end

  def step(state, mod, data \\ nil) do
  	step_def = %Backroll.Step{ref: make_ref(), module: mod, data: data}
    %__MODULE__{state | steps: state.steps ++ [step_def]}
  end

  def on_success(state, fun) do
  	%__MODULE__{state | on_success: fun}
  end

  def on_failure(state, fun) do
  	%__MODULE__{state | on_failure: fun}
  end

  def start(state, supervisor) do
    {:ok, pid} = Supervisor.start_child(supervisor, [state])
    Backroll.Sequence.execute(pid)
  end

  def checkpoint(data, step_data) do
  end
end
