defmodule Ascella.CleanStart do
  @moduledoc """
  How Ascella starts another program: from an empty environment, with a short
  list of what any program of a desktop session may expect, and nothing of
  Ascella's own.

  Ascella is a release, and its launcher exports `PORT=4090`, `ASCELLA_DATA`,
  `RELEASE_*` and the Erlang variables. A program started with those believes
  them. Arkab's launcher read `PORT`, found Ascella answering on 4090,
  concluded it was already running, opened a browser tab and left. A deny-list
  of Ascella's variables would be a list of what we remembered; the program
  should get what Finder, the Start menu or the Desktop would have given it,
  so this is an allow-list: `/usr/bin/env -i NAME=value... program args`.

  What is passed on, when set:

    * `HOME`, `USER`, `LOGNAME`, `LANG`, every `LC_*`;
    * `PATH`: not Ascella's but the system's default;
    * Linux, the session: `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`,
      `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`. Without them a program
      cannot open a window.

  macOS needs no more: with an empty environment `open` hands the app the
  session's normal environment through LaunchServices, as a double-click
  does.

  Not covered, deliberately and checked: systemd starts a unit with its own
  environment (the unit file's `Environment=` lines), and WMI's
  `Win32_Process.Create` (`Ascella.Installer.start_detached/3`) creates the
  process under the WMI service, whose environment is not Ascella's. Both are
  clean already and are left alone.

  One more place needs a program run *and waited for* in a clean environment:
  a Windows `Setup.exe --silent`, whose answer Ascella wants, and which may
  start the app it has just installed. WMI does not wait, so there the
  environment is cleaned the other way round, with a deny-list because Windows
  programs need most of what is set (`unset/1`): the variables of Ascella's
  own release, which are exactly the ones that make a sister program believe
  it is already running.
  """

  @always ~w(HOME USER LOGNAME LANG)
  @session ~w(DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS)

  @macos_path "/usr/bin:/bin:/usr/sbin:/sbin"
  @linux_path "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  @doc """
  `{program, args}` that runs `program args` in a clean environment on this
  system (`family` is `:macos` or `:linux`). `env` is the environment to
  take the allowed names from.
  """
  def command(family, program, args, env \\ System.get_env()) do
    {"/usr/bin/env", ["-i" | assignments(family, env)] ++ [program | args]}
  end

  @doc """
  `[{name, nil}]` for every variable of `env` that belongs to Ascella's own
  release (`PORT`, `ASCELLA_*`, `RELEASE_*`, `PHX_*`, `SECRET_KEY_BASE`, the
  Erlang runtime's), in the form `System.cmd/3`'s `:env` option takes to
  remove them. Case is ignored: Windows does.
  """
  def unset(env \\ System.get_env()) do
    for {name, _} <- env, own?(String.upcase(name)), do: {name, nil}
  end

  @own_exact ~w(PORT SECRET_KEY_BASE BINDIR ROOTDIR EMU PROGNAME ERL_LIBS ERL_FLAGS ERL_AFLAGS
                ERL_ZFLAGS HEART_COMMAND)
  @own_prefix ~w(ASCELLA_ RELEASE_ PHX_ ERL_ ELIXIR_ MIX_)

  defp own?(name), do: name in @own_exact or String.starts_with?(name, @own_prefix)

  @doc "The `NAME=value` words passed to `env -i`."
  def assignments(family, env \\ System.get_env()) do
    names = if family == :linux, do: @always ++ @session, else: @always
    locale = for {name, _} <- env, String.starts_with?(name, "LC_"), do: name

    passed =
      for name <- names ++ Enum.sort(locale),
          value = env[name],
          value != "",
          do: "#{name}=#{value}"

    ["PATH=" <> if(family == :linux, do: @linux_path, else: @macos_path) | passed]
  end
end
