defmodule Ascella.Runner.System do
  @moduledoc "The real runner: `System.cmd/3`, with a missing program as exit status 127 instead of a crash."
  @behaviour Ascella.Runner

  @impl true
  def cmd(program, args, opts) do
    options =
      [stderr_to_stdout: true]
      |> then(&if opts[:cd], do: Keyword.put(&1, :cd, opts[:cd]), else: &1)
      |> then(&if opts[:env], do: Keyword.put(&1, :env, opts[:env]), else: &1)

    exe = if File.regular?(program), do: program, else: System.find_executable(program)

    if exe, do: System.cmd(exe, args, options), else: {"#{program}: not found", 127}
  rescue
    error -> {Exception.message(error), 126}
  end
end
