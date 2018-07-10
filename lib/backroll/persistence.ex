defmodule Backroll.Persistence do
  @callback load_all() :: list({String.t(), %Backroll.Sequence{}})
  @callback enumerate() :: list(String.t())
  @callback load(String.t()) :: %Backroll.Sequence{}
  @callback save(id :: String.t(), data: %Backroll.Sequence{}) :: any()

  @optional_callbacks load_all: 0, enumerate: 0, load: 1
end
