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
    * `:macos_app` - `Ascella.app` on a Mac. `Ascella.SelfUpdate.Mac`
      downloads and verifies the zip, swaps the app for the new one in its
      own folder (the old one kept for a way back), and a detached helper
      opens the new one - or the old one again, if the new one does not
      answer.
    * `:manual` - a portable zip, a checkout, or a Mac app that is not
      inside an `.app`. The page says what to do.

  Nothing is applied without somebody pressing the button, and never while
  Ascella is installing, updating or rolling back something else: `decide/1`
  is the one place that says so, and `Ascella.Apps` is the one that knows.
  Updating all does the other programs first and Ascella last.
  """

  alias Ascella.{Context, Fetch, Paths}
  alias Ascella.SelfUpdate.Mac

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

  @doc "`:velopack`, `:systemd`, `:macos_app` or `:manual`; the installers say which in `ASCELLA_UPDATER`, and the layout on disk has to agree."
  def install_kind do
    case Application.get_env(:ascella, :install_kind) do
      nil -> detect_kind()
      kind when kind in [:velopack, :systemd, :macos_app, :manual] -> kind
    end
  end

  defp detect_kind do
    case System.get_env("ASCELLA_UPDATER") do
      "velopack" -> if velopack_layout?(), do: :velopack, else: :manual
      "systemd" -> if File.dir?(request_dir()), do: :systemd, else: :manual
      "macos-app" -> if Mac.bundle_path(), do: :macos_app, else: :manual
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
  Whether this update may start now. `facts`: `:own` (what `check/1` found,
  or nil), `:current` (the running version), `:busy?` (Ascella is installing,
  updating or rolling back something), `:kind` (see `install_kind/0`),
  `:writable?` and `:bundle` (a Mac copy: whether its folder can be written,
  and where it is).

  `{:ok, kind}`, or `{:error, reason}`: `:no_update`, `:not_newer`,
  `:manual`, `:busy`, `{:not_writable, bundle}`.
  """
  def decide(%{own: own, current: current, busy?: busy?, kind: kind} = facts) do
    cond do
      own == nil ->
        {:error, :no_update}

      not newer?(own.version, current) ->
        {:error, :not_newer}

      kind == :manual ->
        {:error, :manual}

      busy? ->
        {:error, :busy}

      kind == :macos_app and Map.get(facts, :writable?) == false ->
        {:error, {:not_writable, Map.get(facts, :bundle)}}

      true ->
        {:ok, kind}
    end
  end

  @doc "Whether `a` is a newer version than `b`; false when either is not a version."
  def newer?(a, b) do
    with {:ok, a} <- Version.parse(a), {:ok, b} <- Version.parse(b) do
      Version.compare(a, b) == :gt
    else
      _unparsable -> false
    end
  end

  @doc "The facts about this copy's folder that `decide/1` wants, for `kind`."
  def location_facts(:macos_app) do
    bundle = Mac.bundle_path()
    %{bundle: bundle, writable?: is_binary(bundle) and Mac.writable?(bundle)}
  end

  def location_facts(_kind), do: %{}

  @doc "Where the Mac helper leaves its last word: `ok VERSION`, `rolled-back VERSION`, `failed VERSION` or `stuck VERSION`."
  def status_file, do: Path.join(Paths.data(), "self-update-status")

  @doc "The Mac helper's running account of every self-update, beside server.log; kept across restarts."
  def log_file, do: Path.join([Paths.data(), "logs", "self-update.log"])

  @doc "The helper's last word as `{:ok | :rolled_back | :failed | :stuck, version}`, or nil."
  def last_result do
    with {:ok, text} <- File.read(status_file()),
         [word, version] <- String.split(String.trim(text), " ", parts: 2),
         {:ok, state} <-
           Map.fetch(
             %{
               "ok" => :ok,
               "rolled-back" => :rolled_back,
               "failed" => :failed,
               "stuck" => :stuck
             },
             word
           ) do
      {state, version}
    else
      _none -> nil
    end
  end

  @doc """
  Hands the update over. `:ok` (Ascella stops shortly, or the updater has
  its request), `{:error, :manual}`, or `{:error, reason}`. Callers ask
  `decide/1` first; this does not.
  """
  def apply(update, ctx \\ Context.current())

  def apply(%{kind: kind} = update, ctx), do: do_apply(update, kind, ctx)
  def apply(update, ctx), do: do_apply(update, install_kind(), ctx)

  defp do_apply(update, kind, ctx) do
    case kind do
      :manual ->
        {:error, :manual}

      :macos_app ->
        Mac.apply(update, ctx)

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
             :ok <- File.write(Path.join(dir, "request"), update.version <> "\n") do
          :ok
        end
    end
  end
end
