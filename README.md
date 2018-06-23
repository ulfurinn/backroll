# Backroll

Backroll provides interruptible, resumable, and rollbackable data processing pipelines.

[![Build Status](https://travis-ci.org/ulfurinn/backroll.svg?branch=master)](https://travis-ci.org/ulfurinn/backroll)

_Backroll addresses the same fundamental problem as [Sage](https://hex.pm/packages/sage) but it arose out of different procedural requirements, which drove its feature set._

## Installation

```elixir
def deps do
  [
    {:backroll, "~> 1.0.0"}
  ]
end
```

## Basic usage

Have a `Backroll.Supervisor` running somewhere in your application. We will refer to its instance (either a pid or a name) as `supervisor`.

A Backroll sequence is composed of step. Each kind of step is defined by its own module.

Define some steps like so:

```elixir
defmodule Step1 do
  @behaviour Backroll.Step

  def run(data, step_data) do
    # ...
    {:ok, new_data, new_step_data} # or {:ok, new_data}
  end

  def rollback(data, step_data, reason) do
    # ...
    {:ok, new_data, new_step_data} # or {:ok, new_data}
  end
end
```

Create and execute a sequence like so:

```elixir
Backroll.new("some-unique-pipeline-identifier", initial_data)
|> Backroll.step(Step1, initial_step_data)
|> Backroll.on_success(CallbackModule) # or Backroll.on_success(fn data -> ... end)
|> Backroll.on_failure(CallbackModule) # or Backroll.on_failure(fn data, reason -> ... end)
|> Backroll.start(supervisor)
```

A sequence is executed asynchronously, but you can use the success and failure callbacks to send messages back and block on them. `CallbackModule` must define `on_success(data)` and `on_failure(data, reason)`. The choice between callback modules and functions has implications on persistence; see the section on persistence for more details.

`initial_data` will be threaded through all defined steps' `run/2` function, along with private step data. (Multiple steps implemented by the same module will have their own data term.) If a step crashes, all the steps executed so far, together with the crashed one, will run in reverse order with the `rollback/3` function.



## Persistence
