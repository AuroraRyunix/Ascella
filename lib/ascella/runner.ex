defmodule Ascella.Runner do
  @moduledoc """
  How Ascella runs another program: one callback, so that the tests can put
  a fake in its place and nothing on the test machine is ever installed,
  started or stopped (`config/test.exs`).

  `cmd/3` returns `{output, exit_status}`, like `System.cmd/3`. Options:
  `:cd`, `:env` (a list of `{name, value}`), `:timeout` (milliseconds; a
  program still running then is given up on with exit status 124 - the real
  runner does that, the fake never waits).

  Nothing is run without a deadline: `run/4` fills in a short one for the
  programs that only ask a quick question or may be waiting for a person
  (`osascript` when macOS asks for permission, `defaults`, `open`, `pgrep`,
  PowerShell) and a long one for the rest (unpacking, installers).
  """

  @quick_ms 30_000
  @long_ms 600_000
  @quick ~w(osascript defaults killall open pgrep kill tasklist taskkill powershell PlistBuddy
            gsettings xdg-open)

  @callback cmd(String.t(), [String.t()], keyword) :: {String.t(), non_neg_integer}

  @doc "Runs `program` through the context's runner, as root on Linux when Ascella is not."
  def run(ctx, program, args, opts \\ [])

  def run(ctx, program, args, opts) do
    opts = Keyword.put_new(opts, :timeout, timeout_for(program))
    do_run(ctx, program, args, opts)
  end

  defp timeout_for(program),
    do: if(Path.basename(program) in @quick, do: @quick_ms, else: @long_ms)

  defp do_run(%{runner: runner, sudo: true, family: :linux}, program, args, opts) do
    if Keyword.get(opts, :as_root, false),
      do: runner.cmd("sudo", ["-n", program | args], opts),
      else: runner.cmd(program, args, opts)
  end

  defp do_run(%{runner: runner}, program, args, opts), do: runner.cmd(program, args, opts)
end
