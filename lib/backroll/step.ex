defmodule Backroll.Step do
  @doc """
  Executes the step action.

  A two-element tuple will preserve the private step data, a three-element tuple will replace it with the new value.

  Returning `:ok` will finish the step and run the next one, if any.

  Returning `:repeat` will run the same step again with the updated data and step data.
  This can be useful when the step performs multiple lengthy operations sequentially,
  and you don't want to block the application shutdown, should you need it.
  In this case, you can use `:repeat`, and Backroll will take care of interrupting and resuming your sequence.
  Watch out for infinite loops.

  Returning `:await` will pause the sequence and wait for an async input with `Backroll.signal/2`.
  The optional callback `c:handle_signal/2` can be used to merge it with the step data provided during sequence construction.
  """
  @callback run(data :: any(), step_data :: any()) ::
              {:ok | :repeat | :await, data :: any()} | {:ok | :repeat | :await, data :: any(), step_data :: any()}

  @doc """
  Tries to cancel the action performed in `c:run/2`.
  """
  @callback rollback(data :: any(), step_data :: any(), reason :: any()) :: {:ok, data :: any()} | {:ok, data :: any(), step_data :: any()}

  @doc """
  Merges the async signal with the step data.

  If not defined, the signal replaces any step data provided during sequence construction.
  """
  @callback handle_signal(signal :: any(), step_data :: any()) :: any()

  @optional_callbacks handle_signal: 2


  defstruct [
    :ref,
    :module,
    :data,
    {:finished, false},
    {:rolled_back, false}
  ]

  @doc false
  def finished(step),
    do: %__MODULE__{step | finished: true}

  @doc false
  def rolled_back(step),
    do: %__MODULE__{step | rolled_back: true}
end
