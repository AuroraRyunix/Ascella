defmodule Ascella.Launchers.Linux do
  @moduledoc """
  A `.desktop` file in `~/.local/share/applications` (the menu), a copy on
  the Desktop when there is one, and GNOME's favourites through `gsettings`
  when that exists. The icon is the app's mark, written as a standalone SVG
  into Ascella's own launchers folder.
  """
  @behaviour Ascella.Launchers.Adapter

  alias Ascella.{Installer, Runner}

  @schema "org.gnome.shell"
  @key "favorite-apps"

  @impl true
  def kinds(ctx, target) do
    if target[:exec] || target[:wrapper] do
      [:menu] ++
        if(ctx.desktop && File.dir?(ctx.desktop), do: [:desktop], else: []) ++
        if(ctx.gsettings, do: [:favourites], else: [])
    else
      []
    end
  end

  @impl true
  def refreshable, do: [:menu, :desktop]

  @impl true
  def create(:menu, app, target, ctx, existing) do
    write_entry(Path.join(ctx.applications, desktop_id(app)), app, target, existing, false, ctx)
  end

  def create(:desktop, app, target, ctx, existing) do
    write_entry(Path.join(ctx.desktop, app.name <> ".desktop"), app, target, existing, true, ctx)
  end

  def create(:favourites, app, _target, ctx, _existing) do
    id = desktop_id(app)

    with {:ok, list} <- favourites(ctx) do
      if id in list do
        {:error, :already_there}
      else
        with :ok <- set_favourites(ctx, list ++ [id]), do: {:ok, %{"id" => id, "file" => false}}
      end
    end
  end

  @impl true
  def delete(:favourites, _app, %{"id" => id}, ctx) do
    with {:ok, list} <- favourites(ctx) do
      if id in list, do: set_favourites(ctx, List.delete(list, id)), else: :ok
    end
  end

  def delete(_kind, _app, _record, _ctx), do: :ok

  @impl true
  def exists?(:favourites, _record), do: true
  def exists?(_kind, %{"path" => path}), do: File.exists?(path)

  def desktop_id(app), do: "ascella-#{app.id}.desktop"

  defp write_entry(path, app, target, existing, trust?, ctx) do
    if File.exists?(path) and existing == nil do
      {:error, :already_there}
    else
      File.mkdir_p!(Path.dirname(path))

      with :ok <- File.write(path, entry(app, target)),
           :ok <- File.chmod(path, 0o755) do
        # GNOME shows a Desktop file as a launcher only once it is trusted.
        if trust?, do: Runner.run(ctx, "gio", ["set", path, "metadata::trusted", "true"])
        {:ok, %{"path" => path, "file" => true}}
      end
    end
  end

  defp entry(app, target) do
    [
      "[Desktop Entry]",
      "Type=Application",
      "Name=#{app.name}",
      "Comment=#{Map.get(app.blurb, "en", "")}",
      "Exec=#{exec(target)}",
      target.icon && "Icon=#{target.icon}",
      "Terminal=false",
      "Categories=Utility;"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp exec(%{exec: exec, args: args}), do: Enum.map_join([exec | args], " ", &quote_arg/1)

  # The Desktop Entry spec: double quotes, with " ` $ and \ escaped, % doubled.
  defp quote_arg(arg) do
    if arg =~ ~r/\A[A-Za-z0-9_.\/:@+=-]+\z/ do
      arg
    else
      escaped =
        arg
        |> String.replace("\\", "\\\\\\\\")
        |> String.replace(~r/["`$]/, "\\\\\\0")
        |> String.replace("%", "%%")

      ~s("#{escaped}")
    end
  end

  # --- GNOME favourites -------------------------------------------------------------

  defp favourites(ctx) do
    case Runner.run(ctx, "gsettings", ["get", @schema, @key]) do
      {out, 0} ->
        {:ok, ~r/'([^']*)'/ |> Regex.scan(out, capture: :all_but_first) |> List.flatten()}

      {out, status} ->
        {:error, {:exit, "gsettings", status, out}}
    end
  end

  defp set_favourites(ctx, list) do
    value = "[" <> Enum.map_join(list, ", ", &"'#{&1}'") <> "]"
    Installer.run(ctx, "gsettings", ["set", @schema, @key, value])
  end
end
