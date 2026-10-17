defmodule Ascella.Platform do
  @moduledoc """
  Which build of an app this machine wants, named the way the catalogue
  names it: `windows-x86_64`, `macos-aarch64`, `linux-x86_64`,
  `linux-aarch64`. An Intel Mac gets `nil`: nobody builds for it any more,
  and pretending otherwise would only download the wrong thing faster.
  """

  @targets ~w(windows-x86_64 macos-aarch64 linux-x86_64 linux-aarch64)

  def targets, do: @targets

  @doc "The target of this machine, or of the given `os` and `arch`."
  def target(os \\ :os.type(), arch \\ arch()) do
    case {family(os), arch} do
      {:windows, _} -> "windows-x86_64"
      {:macos, "aarch64"} -> "macos-aarch64"
      {:macos, _intel} -> nil
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

  @doc "`x86_64` or `aarch64`, as release assets spell it."
  def arch do
    architecture = to_string(:erlang.system_info(:system_architecture))

    if String.starts_with?(architecture, ["aarch64", "arm64"]), do: "aarch64", else: "x86_64"
  end
end
