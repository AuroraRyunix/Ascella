defmodule Ascella.Platform do
  @moduledoc """
  Which build of an app this machine wants, named the way the catalogue
  names it: `windows-x86_64`, `macos-aarch64`, `linux-x86_64`,
  `linux-aarch64`, `macos-x86_64`. An Intel Mac gets its own target. Whether
  an app has a build for it is the catalogue's business: today none does, and
  Ascella says so rather than download the Apple Silicon zip, which would
  open as "damaged" and explain nothing.
  """

  @targets ~w(windows-x86_64 macos-x86_64 macos-aarch64 linux-x86_64 linux-aarch64)

  def targets, do: @targets

  @doc "The target of this machine, or of the given `os` and `arch`."
  def target(os \\ :os.type(), arch \\ arch()) do
    case {family(os), arch} do
      {:windows, _} -> "windows-x86_64"
      {:macos, arch} -> "macos-" <> arch
      {:linux, arch} -> "linux-" <> arch
    end
  end

  @doc "`:windows`, `:macos` or `:linux` (anything else that is Unix counts as Linux)."
  def family(os \\ :os.type())
  def family({:win32, _}), do: :windows
  def family({:unix, :darwin}), do: :macos
  def family({:unix, _}), do: :linux

  @doc "The family a target belongs to."
  def family_of("windows-" <> _), do: :windows
  def family_of("macos-" <> _), do: :macos
  def family_of("linux-" <> _), do: :linux

  @doc """
  `x86_64` or `aarch64`, as release assets spell it: the machine's, not the
  program's. An x86_64 Ascella under Rosetta on an Apple Silicon Mac is on
  an `aarch64` machine and wants the arm64 builds, which run natively.
  """
  def arch do
    case :persistent_term.get({__MODULE__, :arch}, nil) do
      nil ->
        found = arch(to_string(:erlang.system_info(:system_architecture)), translated?())
        :persistent_term.put({__MODULE__, :arch}, found)
        found

      found ->
        found
    end
  end

  @doc "The machine's architecture, from the Erlang one and whether Rosetta is translating this program."
  def arch(system_architecture, translated?) do
    cond do
      String.starts_with?(system_architecture, ["aarch64", "arm64"]) -> "aarch64"
      translated? -> "aarch64"
      true -> "x86_64"
    end
  end

  # `sysctl.proc_translated` is 1 for a program Rosetta runs, 0 for a native
  # one, and absent (an error) on an Intel Mac and before Rosetta 2.
  defp translated? do
    case :os.type() do
      {:unix, :darwin} ->
        try do
          match?(
            {"1" <> _, 0},
            System.cmd("/usr/sbin/sysctl", ["-n", "sysctl.proc_translated"],
              stderr_to_stdout: true
            )
          )
        rescue
          _ -> false
        end

      _other ->
        false
    end
  end
end
