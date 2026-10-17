defmodule Ascella.Runner do
  @moduledoc """
  How Ascella runs another program: one callback, so that the tests can put
  a fake in its place and nothing on the test machine is ever installed,
  started or stopped (`config/test.exs`).

  `cmd/3` returns `{output, exit_status}`, like `System.cmd/3`. Options:
  `:cd`, `:env` (a list of `{name, value}`).
  """

  @callback cmd(String.t(), [String.t()], keyword) :: {String.t(), non_neg_integer}

  @doc "Runs `program` through the context's runner, as root on Linux when Ascella is not."
  def run(ctx, program, args, opts \\ [])

  def run(%{runner: runner, sudo: true, family: :linux}, program, args, opts) do
    if Keyword.get(opts, :as_root, false),
      do: runner.cmd("sudo", ["-n", program | args], opts),
      else: runner.cmd(program, args, opts)
  end

  def run(%{runner: runner}, program, args, opts), do: runner.cmd(program, args, opts)
end
