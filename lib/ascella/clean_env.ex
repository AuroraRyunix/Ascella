defmodule Ascella.CleanEnv do
  @moduledoc """
  The environment a program Ascella starts must not inherit.

  Ascella is a release, and its launcher exports a handful of variables to
  it: `PORT=4090`, `ASCELLA_DATA`, `RELEASE_*`, the Erlang ones. A program
  started with those in its environment believes them. Arkab's launcher reads
  `PORT`, finds Ascella answering on 4090, concludes that it is already
  running, opens a browser tab and leaves. Correct reasoning, wrong premise.

  So everything Ascella starts gets these variables unset: `unsets/0` is a
  list of `{name, nil}`, which `System.cmd/3` takes as "remove". It is
  computed from the environment this process actually has (the prefixes), plus
  a fixed list of what the launchers (`rel/macos/launcher.sh`, `Launcher.swift`,
  `rel/windows/launcher.c`, `rel/env.*.eex`, `rel/linux/ascella.sh`) and the
  release scripts are known to export.

  Not needed, and checked rather than assumed: systemd starts a unit with its
  own environment (`Environment=` lines, nothing inherited from Ascella), and
  WMI's `Win32_Process.Create` (`Ascella.Installer.start_detached/3`) creates
  the process under the WMI service, not under Ascella.
  """

  @prefixes ~w(ASCELLA_ RELEASE_ ERL_ MIX_ ELIXIR_ PHX_)

  # The names that are known to be exported, set or not; the prefixes catch the rest.
  @fixed ~w(
    PORT SECRET_KEY_BASE DATABASE_PATH BINDIR ROOTDIR EMU PROGNAME ESCRIPT_NAME
    HEART_COMMAND HEART_BEAT_TIMEOUT PHX_SERVER PHX_HOST
    ASCELLA_DATA ASCELLA_UPDATER ASCELLA_LAUNCHER_TOKEN ASCELLA_CATALOGUE ASCELLA_APPS_DIR ASCELLA_RUN_AS
    RELEASE_ROOT RELEASE_NAME RELEASE_VSN RELEASE_NODE RELEASE_COOKIE RELEASE_TMP RELEASE_SYS_CONFIG
    RELEASE_DISTRIBUTION RELEASE_MODE RELEASE_COMMAND RELEASE_PROG ERL_LIBS ERL_AFLAGS ERL_ZFLAGS
  )

  @doc "Names that are always unset."
  def fixed, do: @fixed

  @doc "Prefixes whose variables are all unset."
  def prefixes, do: @prefixes

  @doc "`[{name, nil}]` for `System.cmd/3` / `Ascella.Runner`: the fixed names and every set variable with a known prefix."
  def unsets(env \\ System.get_env()) do
    present = for {name, _value} <- env, String.starts_with?(name, @prefixes), do: name

    (@fixed ++ present) |> Enum.uniq() |> Enum.sort() |> Enum.map(&{&1, nil})
  end
end
