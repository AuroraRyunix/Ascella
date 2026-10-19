defmodule Ascella.Apps do
  @moduledoc """
  The state of every app in the catalogue, kept in one process so that the
  page, a second browser tab and "Update all" agree about it: what is
  installed, what is out, what is running, and what Ascella is busy with.

  Ascella itself is the one thing here that is not in the catalogue, and the
  one thing that must wait for everything else: it updates last, and never
  while anything is being installed, updated or rolled back (`busy?/1` below
  is the single place that knows). Its update stops the program this runs in.

  One action per app at a time. Actions run in tasks, so the page stays
  alive during a download that takes the hall's Wi-Fi five minutes; each
  ends with that app's status read again from the machine, not assumed.

  Unasked, this asks GitHub once at start and every half hour, and looks at
  what is running every ten seconds. It installs nothing that nobody asked
  for.
  """
  use GenServer

  require Logger

  alias Ascella.{Catalogue, Context, Fetch, Installer, Launchers, Updates}

  @topic "apps"
  @look_every :timer.seconds(10)
  @check_every :timer.minutes(30)

  @actions ~w(install update start stop rollback uninstall)a

  # Ascella's place in the busy map and in the queue. No app has this id.
  @self "ascella"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Ascella.PubSub, @topic)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "One map per app, in catalogue order (see `tile/2`)."
  def tiles, do: GenServer.call(__MODULE__, :tiles)

  @doc """
  Ascella's own update, or nil: `%{version, tag, kind, busy?, waiting?, error}`.
  `busy?` while it is under way, `waiting?` while it is queued behind the
  other programs, `error` the last thing that went wrong.
  """
  def own_update, do: GenServer.call(__MODULE__, :own_update)

  @doc "Updates Ascella itself now: `:ok`, or `{:error, reason}` (see `Ascella.Updates.decide/1`)."
  def update_self, do: GenServer.call(__MODULE__, :update_self)

  @doc "Whether anything is being installed, updated or rolled back, or is waiting to be."
  def busy?, do: GenServer.call(__MODULE__, :busy?)

  @doc "Asks GitHub again, for every app and for Ascella itself."
  def check_now, do: GenServer.cast(__MODULE__, :check)

  @doc "Looks at the machine again (installed, running), without GitHub."
  def look_now, do: GenServer.cast(__MODULE__, :look)

  @doc "Starts `action` (#{inspect(@actions)}) for app `id`. `{:error, :busy}` when something is already under way."
  def act(id, action, opts \\ []) when action in @actions,
    do: GenServer.call(__MODULE__, {:act, id, action, opts})

  @doc "Makes launcher `kind` for app `id` (see `Ascella.Launchers`)."
  def add_launcher(id, kind), do: launcher(id, &Launchers.add(&1, kind, &2))

  @doc "Removes launcher `kind` of app `id`, if Ascella made it."
  def remove_launcher(id, kind), do: launcher(id, &Launchers.remove(&1, kind, &2))

  @doc "The Windows folder reveal for a shortcut Ascella made."
  def reveal_launcher(id, kind), do: launcher(id, &Launchers.reveal(&1, kind, &2))

  @doc "Stops offering shortcuts after the install of `id` (they can still be set on the tile)."
  def dismiss_offer(id), do: GenServer.cast(__MODULE__, {:dismiss_offer, id})

  defp launcher(id, fun) do
    result =
      case Catalogue.get(id) do
        nil -> {:error, :unknown}
        app -> fun.(app, Context.current())
      end

    GenServer.cast(__MODULE__, :look)
    result
  end

  @doc """
  Updates every installed app for which a newer release is out, one after
  another, and then Ascella itself when it has an update too (its id,
  "#{@self}", is the last of the ids). `{:error, :updating_self}` while Ascella is
  already replacing itself.
  """
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
      offers: MapSet.new(),
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

  def handle_call(:own_update, _from, state), do: {:reply, own(state), state}

  def handle_call(:busy?, _from, state), do: {:reply, busy?(state), state}

  def handle_call(:update_self, _from, state) do
    case decide_self(state) do
      {:ok, _kind} ->
        {:reply, :ok, run_self(%{state | queue: state.queue -- [@self]})}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:act, id, action, opts}, _from, state) do
    case Catalogue.get(id) do
      nil ->
        {:reply, {:error, :unknown}, state}

      app ->
        cond do
          Map.has_key?(state.busy, @self) ->
            {:reply, {:error, :updating_self}, state}

          Map.has_key?(state.busy, id) ->
            {:reply, {:error, :busy}, state}

          true ->
            state = run(app, action, opts, state)
            {:reply, :ok, state}
        end
    end
  end

  def handle_call(:update_all, _from, %{busy: %{@self => _}} = state),
    do: {:reply, {:error, :updating_self}, state}

  def handle_call(:update_all, _from, state) do
    ids =
      for app <- Catalogue.apps(),
          tile = tile(app, state),
          tile.update?,
          not Map.has_key?(state.busy, app.id),
          do: app.id

    ids = if self_due?(state), do: ids ++ [@self], else: ids
    state = %{state | queue: state.queue ++ (ids -- state.queue)}
    {:reply, {:ok, ids}, state |> next_in_queue() |> broadcast()}
  end

  @impl true
  def handle_cast(:look, state), do: {:noreply, state |> look() |> broadcast()}

  def handle_cast({:dismiss_offer, id}, state),
    do: {:noreply, broadcast(%{state | offers: MapSet.delete(state.offers, id)})}

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

    # A first install is when shortcuts are offered; an uninstall ends the offer.
    offers =
      cond do
        result == :ok and action == :install -> MapSet.put(state.offers, id)
        action == :uninstall -> MapSet.delete(state.offers, id)
        true -> state.offers
      end

    state = %{state | busy: Map.delete(state.busy, id), errors: errors, offers: offers}
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
      rollback?: app.rollback,
      latest: latest_version,
      latest_error: match?({:error, _}, latest) && elem(latest, 1),
      running?: Map.get(state.running, app.id, false),
      busy: Map.get(state.busy, app.id) || if(app.id in state.queue, do: :queued),
      launchers: if(status.state == :installed, do: Launchers.options(app, ctx), else: []),
      offer?: MapSet.member?(state.offers, app.id),
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

  defp run(app, action, opts, state) do
    ctx = Context.current()
    release = release_for(app, state)

    task =
      Task.Supervisor.async_nolink(Ascella.TaskSupervisor, fn ->
        result =
          try do
            perform(action, app, release, ctx, opts)
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

  defp perform(action, _app, nil, _ctx, _opts) when action in [:install, :update],
    do: {:error, :no_release}

  defp perform(action, app, release, ctx, _opts) when action in [:install, :update] do
    with :ok <- Installer.install(app, release, ctx), do: Launchers.refresh(app, ctx)
  end

  defp perform(:start, app, _release, ctx, _opts), do: Installer.start(app, ctx)
  defp perform(:stop, app, _release, ctx, _opts), do: Installer.stop(app, ctx)

  defp perform(:rollback, app, _release, ctx, _opts) do
    with :ok <- Installer.rollback(app, ctx), do: Launchers.refresh(app, ctx)
  end

  defp perform(:uninstall, app, _release, ctx, opts),
    do: Installer.uninstall(app, ctx, delete_data: opts[:delete_data] == true)

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

      cond do
        id == @self -> next_self(state)
        app = Catalogue.get(id) -> run(app, :update, [], state)
        true -> next_in_queue(state)
      end
    end
  end

  # Ascella's turn, last in the queue. Asked again, not assumed: the others
  # may have taken a while, and a refusal is shown on the page, not lost.
  defp next_self(state) do
    case decide_self(state) do
      {:ok, _kind} ->
        run_self(state)

      {:error, reason} ->
        broadcast(%{state | errors: Map.put(state.errors, @self, {:update, reason})})
    end
  end

  # --- Ascella itself ------------------------------------------------------------

  # The single answer to "is anything under way". The queue counts, except
  # for Ascella's own place in it: that is what is waiting for the answer.
  defp busy?(state), do: map_size(state.busy) > 0 or Enum.any?(state.queue, &(&1 != @self))

  defp decide_self(state) do
    kind = Updates.install_kind()

    Updates.decide(
      Map.merge(
        %{
          own: state.own,
          current: Updates.current_version(),
          busy?: busy?(state),
          kind: kind
        },
        Updates.location_facts(kind)
      )
    )
  end

  # Whether "Update all" has Ascella's own update to add to the list.
  defp self_due?(state) do
    state.own != nil and Updates.newer?(state.own.version, Updates.current_version()) and
      state.own.kind != :manual
  end

  defp own(%{own: nil}), do: nil

  defp own(state) do
    Map.merge(state.own, %{
      busy?: Map.has_key?(state.busy, @self),
      waiting?: @self in state.queue,
      error: Map.get(state.errors, @self)
    })
  end

  defp run_self(state) do
    ctx = Context.current()
    own = state.own

    Task.Supervisor.async_nolink(Ascella.TaskSupervisor, fn ->
      result =
        try do
          Updates.apply(own, ctx)
        rescue
          error -> {:error, Exception.message(error)}
        end

      {:done, @self, :update_self, result}
    end)

    broadcast(%{
      state
      | busy: Map.put(state.busy, @self, :update_self),
        errors: Map.delete(state.errors, @self)
    })
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
             previous: nil,
             failed: true
           })
         ), Map.put(running, app.id, safely(fn -> Installer.running?(app, ctx) end, false))}
      end)

    forget_launchers(status, state, ctx)
    changed? = status != state.status or running != state.running
    state = %{state | status: status, running: running}
    if changed?, do: broadcast(state), else: state
  end

  # An app removed by something other than Ascella (its own uninstaller)
  # leaves shortcuts that point at nothing. Cleaned when it was seen
  # installed before and is plainly gone now - not when looking failed.
  defp forget_launchers(status, state, ctx) do
    for {id, %{state: :absent} = now} <- status,
        not Map.has_key?(now, :failed),
        Map.get(state.status, id, %{state: :absent}).state == :installed,
        app = Catalogue.get(id) do
      safely(fn -> Launchers.remove_all(app, ctx) end, :ok)
    end

    :ok
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
