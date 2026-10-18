defmodule Ascella.Updates do
  @moduledoc """
  Ascella's own update, the way Alnasl does its own (`Alnasl.Updates`),
  because a program that updates everything else and not itself would be
  the cobbler's children all over again.

  How it is applied depends on how this copy was installed
  (`install_kind/0`):

    * `:velopack` - the Windows installer. This program stops with exit code
      90; `rel/windows/launcher.c` sees that code, has Velopack apply the
      update, and starts the new version (or the old one, when anything
      went wrong).
    * `:systemd` - the Linux installer. The version goes into
      `<data>/update/request`; a path unit sees it and runs
      `/opt/ascella/update.sh`, which downloads, verifies, switches and
      restarts - or switches back.
    * `:manual` - `Ascella.app` on a Mac, a portable zip, a checkout. The
      page says what to do. On a Mac that is the one Terminal line in
      docs/macos.md, which is also how Ascella got there the first time.

  Nothing is applied without somebody pressing the button.
  """

  alias Ascella.{Fetch, Paths}

  @repo "teapot-chess/Ascella"
  @update_exit_code 90

  def repo, do: @repo
  def releases_page, do: "https://github.com/#{@repo}/releases"
  def update_exit_code, do: @update_exit_code

  @doc "The version that is running."
  def current_version, do: to_string(Application.spec(:ascella, :vsn))

  @doc "A newer Ascella, `%{version, tag, kind}`, or nil."
  def check(ctx) do
    case Fetch.latest(@repo, ctx.github) do
      {:ok, %{version: version, tag: tag}} ->
        if Version.compare(version, current_version()) == :gt,
          do: %{version: version, tag: tag, kind: install_kind()}

      _nothing ->
        nil
    end
  end

  @doc "`:velopack`, `:systemd` or `:manual`; the installers say which in `ASCELLA_UPDATER`, and the layout on disk has to agree."
  def install_kind do
    case Application.get_env(:ascella, :install_kind) do
      nil -> detect_kind()
      kind when kind in [:velopack, :systemd, :manual] -> kind
    end
  end

  defp detect_kind do
    case System.get_env("ASCELLA_UPDATER") do
      "velopack" -> if velopack_layout?(), do: :velopack, else: :manual
      "systemd" -> if File.dir?(request_dir()), do: :systemd, else: :manual
      _none -> :manual
    end
  end

  defp velopack_layout? do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         expanded = Path.expand(root),
         "current" <- Path.basename(expanded) do
      File.exists?(Path.join(Path.dirname(expanded), "Update.exe"))
    else
      _other -> false
    end
  end

  @doc "Where the Linux installation leaves its request for the updater."
  def request_dir, do: Path.join(Paths.data(), "update")

  @doc """
  Hands the update over. `:ok` (Ascella stops shortly, or the updater has
  its request), `{:error, :manual}`, or `{:error, reason}`.
  """
  def apply(%{version: version}) do
    case install_kind() do
      :manual ->
        {:error, :manual}

      :velopack ->
        stop = Application.get_env(:ascella, :updates_stop_fun, &System.stop/1)

        Task.Supervisor.start_child(Ascella.TaskSupervisor, fn ->
          Process.sleep(500)
          stop.(@update_exit_code)
        end)

        :ok

      :systemd ->
        dir = request_dir()

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(Path.join(dir, "request"), version <> "\n") do
          :ok
        end
    end
  end
end
