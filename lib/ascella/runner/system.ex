defmodule Ascella.Runner.System do
  @moduledoc """
  The real runner: `System.cmd/3`, with a missing program as exit status 127
  instead of a crash, and a program that does not finish as exit status 124
  (`timeout`'s own number) instead of a wait that never ends. The deadline is
  `opts[:timeout]` in milliseconds; `Ascella.Runner.run/4` always sets one.
  """
  @behaviour Ascella.Runner

  @default_timeout 300_000

  @impl true
  def cmd(program, args, opts) do
    options =
      [stderr_to_stdout: true]
      |> then(&if opts[:cd], do: Keyword.put(&1, :cd, opts[:cd]), else: &1)
      |> then(&if opts[:env], do: Keyword.put(&1, :env, opts[:env]), else: &1)

    exe = if File.regular?(program), do: program, else: System.find_executable(program)

    if exe,
      do: bounded(exe, args, options, Keyword.get(opts, :timeout, @default_timeout)),
      else: {"#{program}: not found", 127}
  rescue
    error -> {Exception.message(error), 126}
  end

  # The command runs in a task of its own, so that the deadline can end the
  # wait. The port closes with the task; a program that ignores a closed pipe
  # is then somebody else's to stop, but nobody is waiting for it any more.
  defp bounded(exe, args, options, timeout) do
    task = Task.async(fn -> System.cmd(exe, args, options) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {"#{Path.basename(exe)} crashed: #{inspect(reason)}", 126}
      nil -> {"#{Path.basename(exe)}: no answer within #{div(timeout, 1000)} seconds", 124}
    end
  end
end
