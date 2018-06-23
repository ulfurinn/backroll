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

  @opaque t :: %Backroll{}

  @spec new(id :: String.t(), data :: any()) :: Backroll.t()
  def new(id, data) do
    %__MODULE__{
      id: id,
      data: data,
    }
  end

  @doc "Adds a step to the sequence."
  @spec step(state :: Backroll.t(), mod :: module(), data :: any()) :: Backroll.t()
  def step(state, mod, data \\ nil) do
    step_def = %Backroll.Step{ref: make_ref(), module: mod, data: data}
    %__MODULE__{state | steps: state.steps ++ [step_def]}
  end

  @doc """
  Specifies the success callback.

  In the function form, the function will be called with `data`.
  In the module form, the module's `on_success/1` function will be called with `data`.
  """
  @spec on_success(state :: Backroll.t(), fun :: module() | (any() -> any())) :: Backroll.t()
  def on_success(state, fun) do
    %__MODULE__{state | on_success: fun}
  end

  @doc """
  Specifies the failure callback.

  In the function form, the function will be called with `data, reason`.
  In the module form, the module's `on_failure/2` function will be called with `data, reason`.
  """
  @spec on_failure(state :: Backroll.t(), fun :: module() | (any(), any() -> any())) :: Backroll.t()
  def on_failure(state, fun) do
    %__MODULE__{state | on_failure: fun}
  end

  @spec start(state :: Backroll.t(), supervisor:: pid() | atom()) :: pid() | nil
  def start(state, supervisor) do
    {:ok, pid} = Supervisor.start_child(supervisor, [state])
    Backroll.Sequence.execute(pid)
  end

  def checkpoint(data, step_data) do
  end
end
