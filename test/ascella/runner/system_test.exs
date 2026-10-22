defmodule Ascella.Runner.SystemTest do
  use ExUnit.Case, async: true

  alias Ascella.Runner.System, as: Real

  # The command that killed Ascella raised inside its task, while the port
  # was being opened. Bad arguments raise in the same place, and are easier
  # to come by on demand than a system out of processes.
  test "a command that raises is a failed answer, not the caller's death" do
    exe = System.find_executable("elixir") || System.find_executable("erl")

    assert {message, 126} = Real.cmd(exe, [:not_a_string], timeout: 5_000)
    assert is_binary(message)
  end

  test "a program that is not there is 127" do
    assert {_, 127} = Real.cmd("ascella-no-such-program", [], timeout: 5_000)
  end
end
