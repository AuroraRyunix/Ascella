defmodule Ascella.FakeRunner do
  @moduledoc """
  The runner the tests use: it runs nothing. Every call is recorded for the
  test process that owns it, and answered by the script that test gave it
  (`script/1`), or with `{"", 1}` - "not found, not running, did not work" -
  when there is none. A test that forgets to script something gets a
  program that did nothing, which is the one safe default.
  """
  @behaviour Ascella.Runner

  @doc "Answers calls with `fun.(program, args, opts)`, for this test and the processes it starts."
  def script(fun) when is_function(fun, 3) do
    :persistent_term.put({__MODULE__, :script}, fun)
    :persistent_term.put({__MODULE__, :calls}, [])
    :ok
  end

  def reset do
    :persistent_term.erase({__MODULE__, :script})
    :persistent_term.put({__MODULE__, :calls}, [])
  end

  @doc "Forgets the calls so far, keeps the script: for asserting on one action alone."
  def clear, do: :persistent_term.put({__MODULE__, :calls}, [])

  @doc "Every call so far, oldest first: `{program, args}`."
  def calls, do: Enum.reverse(:persistent_term.get({__MODULE__, :calls}, []))

  @impl true
  def cmd(program, args, opts) do
    :persistent_term.put({__MODULE__, :calls}, [
      {program, args} | :persistent_term.get({__MODULE__, :calls}, [])
    ])

    case :persistent_term.get({__MODULE__, :script}, nil) do
      nil -> {"", 1}
      fun -> fun.(program, args, opts)
    end
  end
end
