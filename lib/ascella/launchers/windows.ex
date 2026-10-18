defmodule Ascella.Launchers.Windows do
  @moduledoc """
  Start menu and Desktop shortcuts: `.lnk` files made by PowerShell's
  `WScript.Shell`. The values go in through environment variables, not into
  the script text, so no name can bring its own quote.

  There is deliberately no "pin to taskbar". Windows 10 closed that door and
  the ways round it are verbs and registry tricks that stop working without
  notice. The Start menu shortcut is made, and the page says to right-click
  it and choose Pin to taskbar.
  """
  @behaviour Ascella.Launchers.Adapter

  alias Ascella.Installer

  @script """
  $ErrorActionPreference = 'Stop'
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:ASCELLA_LNK)
  $s.TargetPath = $env:ASCELLA_TARGET
  $s.Arguments = $env:ASCELLA_ARGS
  $s.WorkingDirectory = $env:ASCELLA_WORKDIR
  if ($env:ASCELLA_ICON) { $s.IconLocation = $env:ASCELLA_ICON + ',0' }
  $s.Description = $env:ASCELLA_NAME
  $s.Save()
  """

  @impl true
  def kinds(ctx, target) do
    if target[:exec] || target[:wrapper],
      do: Enum.filter([:start_menu, :desktop], &(folder(&1, ctx) != nil)),
      else: []
  end

  @impl true
  def refreshable, do: [:start_menu, :desktop]

  @impl true
  def create(kind, app, target, ctx, existing) do
    path = Path.join(folder(kind, ctx), app.name <> ".lnk")

    if File.exists?(path) and existing == nil do
      {:error, :already_there}
    else
      File.mkdir_p!(Path.dirname(path))

      env = [
        {"ASCELLA_LNK", path},
        {"ASCELLA_TARGET", target.exec},
        {"ASCELLA_ARGS", Enum.join(target.args, " ")},
        {"ASCELLA_WORKDIR", target.workdir || Path.dirname(target.exec)},
        {"ASCELLA_ICON", target.icon || ""},
        {"ASCELLA_NAME", app.name}
      ]

      args = ["-NoProfile", "-NonInteractive", "-Command", @script]

      with :ok <- Installer.run(ctx, "powershell", args, env: env) do
        if File.exists?(path),
          do: {:ok, %{"path" => path, "file" => true}},
          else: {:error, :not_made}
      end
    end
  end

  @impl true
  def delete(_kind, _app, _record, _ctx), do: :ok

  @impl true
  def exists?(_kind, %{"path" => path}, _ctx), do: File.exists?(path)

  defp folder(:start_menu, ctx), do: ctx.start_menu
  defp folder(:desktop, ctx), do: ctx.desktop
end
