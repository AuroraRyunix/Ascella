defmodule Ascella.Apps do
  @moduledoc """
  The state of every app in the catalogue, kept in one process so that the
  page, a second browser tab and "Update all" agree about it: what is
  installed, what is out, what is running, and what Ascella is busy with.

  One action per app at a time. Actions run in tasks, so the page stays
  alive during a download that takes the hall's Wi-Fi five minutes; each
  ends with that app's status read again from the machine, not assumed.

  Unasked, this asks GitHub once at start and every half hour, and looks at
  what is running every ten seconds. It installs nothing that nobody asked
  for.
  """
  use GenServer

  require Logger

  alias Ascella.{Catalogue, Context, Fetch, Installer, Updates}

  @topic "apps"
  @look_every :timer.seconds(10)
  @check_every :timer.minutes(30)

  @actions ~w(install update start stop rollback)a

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Ascella.PubSub, @topic)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "One map per app, in catalogue order (see `tile/2`)."
  def tiles, do: GenServer.call(__MODULE__, :tiles)

  @doc "Ascella's own update, or nil: `%{version, kind}`."
  def own_update, do: GenServer.call(__MODULE__, :own_update)

  @doc "Asks GitHub again, for every app and for Ascella itself."
  def check_now, do: GenServer.cast(__MODULE__, :check)

  @doc "Looks at the machine again (installed, running), without GitHub."
  def look_now, do: GenServer.cast(__MODULE__, :look)

  @doc "Starts `action` (#{inspect(@actions)}) for app `id`. `{:error, :busy}` when something is already under way."
  def act(id, action) when action in @actions, do: GenServer.call(__MODULE__, {:act, id, action})

  @doc "Updates every installed app for which a newer release is out, one after another."
  def update_all, do: GenServer.call(__MODULE__, :update_all)

  # --- the process -----------------------------------------------------------------

  @impl true
  def init(opts) do
    auto? = Keyword.get(opts, :auto, Application.get_env(:ascella, :apps_auto, true))

    state = %{
      auto?: auto?,
      status: %{},
      running: %{},
      latest: %{},
      own: nil,
      busy: %{},
      errors: %{},
      queue: []
    }

    if auto? do
      send(self(), :look)
      send(self(), :check)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:tiles, _from, state) do
    {:reply, Enum.map(Catalogue.apps(), &tile(&1, state)), state}
  end

  def handle_call(:own_update, _from, state), do: {:reply, state.own, state}

  def handle_call({:act, id, action}, _from, state) do
    case Catalogue.get(id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      app ->
        if Map.has_key?(state.busy, id) do
          {:reply, {:error, :busy}, state}
        else
          state = run(app, action, state)
          {:reply, :ok, state}
        end
    end
  end

  def handle_call(:update_all, _from, state) do
    ids =
      for app <- Catalogue.apps(),
          tile = tile(app, state),
          tile.update?,
          not Map.has_key?(state.busy, app.id),
          do: app.id

    state = %{state | queue: state.queue ++ (ids -- state.queue)}
    {:reply, {:ok, ids}, state |> next_in_queue() |> broadcast()}
  end

  @impl true
  def handle_cast(:look, state), do: {:noreply, look(state)}
  def handle_cast(:check, state), do: {:noreply, check(state)}

  @impl true
  def handle_info(:look, state) do
    if state.auto?, do: Process.send_after(self(), :look, @look_every)
    {:noreply, look(state)}
  end

  def handle_info(:check, state) do
    if state.auto?, do: Process.send_after(self(), :check, @check_every)
    {:noreply, check(state)}
  end

  def handle_info({:checked, results, own}, state) do
    {:noreply, broadcast(%{state | latest: Map.merge(state.latest, results), own: own})}
  end

  def handle_info({ref, {:done, id, action, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if result != :ok,
      do: Logger.warning("Ascella: #{action} #{id}: #{inspect(result)}"),
      else: Logger.info("Ascella: #{action} #{id}: done")

    errors =
      case result do
        :ok -> Map.delete(state.errors, id)
        {:error, reason} -> Map.put(state.errors, id, {action, reason})
        other -> Map.put(state.errors, id, {action, other})
      end

    state = %{state | busy: Map.delete(state.busy, id), errors: errors}
    {:noreply, state |> look() |> next_in_queue() |> broadcast()}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # A task that crashed: whichever app it was for is not busy any more.
    Logger.error("Ascella: an action crashed: #{inspect(reason)}")
    {:noreply, state |> Map.put(:busy, %{}) |> look() |> broadcast()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- what is shown ------------------------------------------------------------------

  @doc false
  def tile(app, state) do
    ctx = Context.current()
    status = Map.get(state.status, app.id, %{state: :absent, version: nil, previous: nil})
    latest = Map.get(state.latest, app.id)
    build? = Installer.for(app, ctx) != nil

    latest_version =
      case latest do
        {:ok, %{version: v}} -> v
        _none -> nil
      end

    %{
      app: app,
      build?: build?,
      state: status.state,
      version: status.version,
      previous: status.previous,
      latest: latest_version,
      latest_error: match?({:error, _}, latest) && elem(latest, 1),
      running?: Map.get(state.running, app.id, false),
      busy: Map.get(state.busy, app.id) || if(app.id in state.queue, do: :queued),
      error: Map.get(state.errors, app.id),
      update?:
        status.state == :installed and is_binary(latest_version) and is_binary(status.version) and
          newer?(latest_version, status.version)
    }
  end

  defp newer?(a, b) do
    with {:ok, a} <- Version.parse(a),
         {:ok, b} <- Version.parse(b),
         do: Version.compare(a, b) == :gt
  end

  # --- doing ------------------------------------------------------------------------

  defp run(app, action, state) do
    ctx = Context.current()
    release = release_for(app, state)

    task =
      Task.Supervisor.async_nolink(Ascella.TaskSupervisor, fn ->
        result =
          try do
            perform(action, app, release, ctx)
          rescue
            error -> {:error, Exception.message(error)}
          end

        {:done, app.id, action, result}
      end)

    _ = task

    broadcast(%{
      state
      | busy: Map.put(state.busy, app.id, action),
        errors: Map.delete(state.errors, app.id)
    })
  end

  defp perform(action, _app, nil, _ctx) when action in [:install, :update],
    do: {:error, :no_release}

  defp perform(action, app, release, ctx) when action in [:install, :update],
    do: Installer.install(app, release, ctx)

  defp perform(:start, app, _release, ctx), do: Installer.start(app, ctx)
  defp perform(:stop, app, _release, ctx), do: Installer.stop(app, ctx)
  defp perform(:rollback, app, _release, ctx), do: Installer.rollback(app, ctx)

  defp release_for(app, state) do
    case Map.get(state.latest, app.id) do
      {:ok, %{version: version, tag: tag}} -> %{version: version, tag: tag}
      _none -> nil
    end
  end

  defp next_in_queue(%{queue: []} = state), do: state

  defp next_in_queue(%{queue: [id | rest]} = state) do
    if map_size(state.busy) > 0 do
      state
    else
      state = %{state | queue: rest}

      case Catalogue.get(id) do
        nil -> next_in_queue(state)
        app -> run(app, :update, state)
      end
    end
  end

  # --- looking ------------------------------------------------------------------------

  defp look(state) do
    ctx = Context.current()

    {status, running} =
      Catalogue.apps()
      |> Enum.reject(&Map.has_key?(state.busy, &1.id))
      |> Enum.reduce({state.status, state.running}, fn app, {status, running} ->
        {Map.put(
           status,
           app.id,
           safely(fn -> Installer.installed(app, ctx) end, %{
             state: :absent,
             version: nil,
             previous: nil
           })
         ), Map.put(running, app.id, safely(fn -> Installer.running?(app, ctx) end, false))}
      end)

    changed? = status != state.status or running != state.running
    state = %{state | status: status, running: running}
    if changed?, do: broadcast(state), else: state
  end

  defp check(state) do
    parent = self()
    ctx = Context.current()

    Task.Supervisor.start_child(Ascella.TaskSupervisor, fn ->
      results =
        Catalogue.apps()
        |> Task.async_stream(fn app -> {app.id, Fetch.latest(app.repo, ctx.github)} end,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, pair} -> [pair]
          _timeout -> []
        end)
        |> Map.new()

      send(parent, {:checked, results, Updates.check(ctx)})
    end)

    state
  end

  defp safely(fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.debug("Ascella: looking failed: #{Exception.message(error)}")
      fallback
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Ascella.PubSub, @topic, :apps_changed)
    state
  end
end
