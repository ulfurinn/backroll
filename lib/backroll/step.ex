defmodule Backroll.Step do
  @callback run(data :: any(), step_data :: any()) ::
              {:ok | :repeat | :await, any()} | {:ok | :repeat | :await, any(), any()}
  @callback rollback(data :: any(), step_data :: any(), reason :: any()) :: {:ok, any(), any()}

  defstruct [
    :ref,
    :module,
    :data,
    {:finished, false},
    {:rolled_back, false}
  ]

  def finished(step),
    do: %__MODULE__{step | finished: true}
  def rolled_back(step),
    do: %__MODULE__{step | rolled_back: true}
end
