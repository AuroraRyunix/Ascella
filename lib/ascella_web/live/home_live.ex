defmodule AscellaWeb.HomeLive do
  @moduledoc """
  The one page: a tile per app with what is installed, what is out and
  whether it runs, and the buttons that change that. Everything it shows
  comes from `Ascella.Apps`; everything it does goes there too.
  """
  use AscellaWeb, :live_view

  alias Ascella.{Apps, Context, Fetch, Launchers, Updates}
  alias AscellaWeb.{Logo, ReleaseNotes, Words}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Apps.subscribe()

    {:ok,
     socket
     |> assign(:own_message, nil)
     |> assign(:removing, nil)
     |> assign(:confirm_data, nil)
     |> assign(:notes, %{})
     |> assign(:whats_new, %{})
     |> load()}
  end

  @impl true
  def handle_info(:apps_changed, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("act", %{"id" => id, "action" => action}, socket)
      when action in ~w(install update start stop rollback) do
    case Apps.act(id, String.to_existing_atom(action)) do
      :ok ->
        {:noreply, load(socket)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("Ascella is already busy with that app."))}

      {:error, :updating_self} ->
        {:noreply, put_flash(socket, :error, Words.reason(:updating_self))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("launcher", %{"id" => id, "kind" => kind, "on" => on}, socket)
      when kind in ~w(start_menu desktop dock login menu favourites) do
    kind = String.to_existing_atom(kind)

    {result, note} =
      if on == "true",
        do: {Apps.add_launcher(id, kind), launcher_note(kind)},
        else: {Apps.remove_launcher(id, kind), nil}

    {:noreply, socket |> note(id, result, note) |> load()}
  end

  def handle_event("offer", %{"id" => id, "answer" => "yes"}, socket) do
    ctx = Context.current()

    results = for kind <- Launchers.defaults(ctx), do: {kind, Apps.add_launcher(id, kind)}
    Apps.dismiss_offer(id)

    socket =
      Enum.reduce(results, socket, fn {kind, result}, socket ->
        note(socket, id, result, launcher_note(kind))
      end)

    {:noreply, load(socket)}
  end

  def handle_event("offer", %{"id" => id, "answer" => "no"}, socket) do
    Apps.dismiss_offer(id)
    {:noreply, load(socket)}
  end

  def handle_event("reveal", %{"id" => id, "kind" => "start_menu"}, socket) do
    Apps.reveal_launcher(id, :start_menu)
    {:noreply, socket}
  end

  def handle_event("remove_ask", %{"id" => id}, socket),
    do: {:noreply, assign(socket, removing: id, confirm_data: nil)}

  def handle_event("remove_cancel", _params, socket),
    do: {:noreply, assign(socket, removing: nil, confirm_data: nil)}

  def handle_event("remove", %{"app_id" => id} = params, socket) do
    if params["delete_data"] == "true",
      do: {:noreply, assign(socket, :confirm_data, id)},
      else: remove(socket, id, false)
  end

  def handle_event("remove_with_data", %{"id" => id}, socket), do: remove(socket, id, true)

  def handle_event("update_all", _params, socket) do
    case Apps.update_all() do
      {:ok, []} ->
        {:noreply, socket |> put_flash(:info, gettext("Everything is up to date.")) |> load()}

      {:ok, _ids} ->
        {:noreply, load(socket)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, Words.reason(reason)) |> load()}
    end
  end

  def handle_event("check", _params, socket) do
    Apps.check_now()
    {:noreply, put_flash(socket, :info, gettext("Asking GitHub."))}
  end

  # What's new: open asks GitHub for the notes in the background, a second
  # press closes it. Nothing here is on the way of the update buttons.
  def handle_event("whats_new", %{"id" => key}, socket) do
    cond do
      Map.has_key?(socket.assigns.whats_new, key) ->
        {:noreply, update(socket, :whats_new, &Map.delete(&1, key))}

      args = notes_args(socket, key) ->
        {repo, installed, latest, github} = args

        {:noreply,
         socket
         |> update(:whats_new, &Map.put(&1, key, :loading))
         |> start_async({:notes, key}, fn -> Fetch.notes(repo, installed, latest, github) end)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("update_self", _params, socket) do
    case Apps.update_self() do
      :ok ->
        {:noreply,
         assign(
           socket,
           :own_message,
           gettext("Ascella is updating itself. This page comes back in a minute.")
         )}

      {:error, reason} when reason in [:manual, :no_update] ->
        {:noreply, load(socket)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, Words.reason(reason)) |> load()}
    end
  end

  @impl true
  def handle_async({:notes, key}, result, socket) do
    outcome =
      case result do
        {:ok, {:ok, notes}} -> {:ok, notes}
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, {:offline, reason}}
      end

    # Closed in the meantime: nobody is waiting for the answer.
    if Map.has_key?(socket.assigns.whats_new, key),
      do: {:noreply, update(socket, :whats_new, &Map.put(&1, key, outcome))},
      else: {:noreply, socket}
  end

  defp notes_args(socket, "ascella") do
    own = socket.assigns.own
    own && {Updates.repo(), Updates.current_version(), own.version, Context.current().github}
  end

  defp notes_args(socket, id) do
    tile = Enum.find(socket.assigns.tiles, &(&1.app.id == id))

    tile && tile.update? && tile.latest &&
      {tile.app.repo, tile.version, tile.latest, Context.current().github}
  end

  defp remove(socket, id, delete_data?) do
    socket = assign(socket, removing: nil, confirm_data: nil)

    case Apps.act(id, :uninstall, delete_data: delete_data?) do
      :ok ->
        {:noreply, load(socket)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("Ascella is already busy with that app."))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp self_note({:rolled_back, version}),
    do:
      gettext(
        "The update to Ascella %{version} did not start, so the previous version was put back. Nothing else was changed.",
        version: version
      )

  defp self_note({:failed, version}),
    do:
      gettext(
        "The update to Ascella %{version} did not start, and the previous version could not be put back. Ascella.app is in its folder; the previous one is in .ascella-previous beside it.",
        version: version
      )

  defp self_note({:stuck, version}),
    do:
      gettext(
        "The update to Ascella %{version} is in place, but the old Ascella did not quit in time, so the new one was not opened. Quit Ascella and open it again.",
        version: version
      )

  defp launcher_note(:start_menu), do: :pin_taskbar
  defp launcher_note(_kind), do: nil

  defp note(socket, id, :ok, note), do: update(socket, :notes, &Map.put(&1, id, note))

  defp note(socket, id, {:error, reason}, _note),
    do: update(socket, :notes, &Map.put(&1, id, {:error, reason}))

  # Ascella's own update counts for "Update all" when it can be applied here.
  defp own_due?(own), do: own != nil and own.kind != :manual

  defp load(socket) do
    tiles = Apps.tiles()
    own = Apps.own_update()

    socket
    |> assign(:tiles, tiles)
    |> assign(:own, own)
    |> assign(:updates, Enum.count(tiles, & &1.update?) + if(own_due?(own), do: 1, else: 0))
    |> assign(:last_self, Updates.last_result())
    |> assign(:default_kinds, Launchers.defaults(Context.current()))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <section class="intro">
        <div>
          <h1>{gettext("The hall's programs")}</h1>
          
          <p class="lede">
            {gettext(
              "Installed, updated, started and stopped from here. Their data is never touched."
            )}
          </p>
        </div>
        
        <div class="intro-actions">
          <button id="check-now" class="btn btn-quiet" phx-click="check">
            {gettext("Check for updates")}
          </button>
          
          <button
            id="update-all"
            class="btn btn-primary"
            phx-click="update_all"
            disabled={@updates == 0}
          >
            {gettext("Update all")} <span :if={@updates > 0} class="count">{@updates}</span>
          </button>
        </div>
      </section>
      
      <div :if={@last_self && elem(@last_self, 0) != :ok} id="self-update-note" class="own-update">
        <p>{self_note(@last_self)}</p>
      </div>
      
      <div :if={@own} id="own-update" class="own-update">
        <div>
          <p>
            {gettext("Ascella %{version}, update available.", version: @own.version)}
            <span class="muted">
              {gettext("This is %{current}.", current: Updates.current_version())}
            </span>
             <span :if={@own_message}>{@own_message}</span>
            <span :if={@own.waiting?} id="own-waiting">
              {gettext("Waiting for the other programs to finish first.")}
            </span>
          </p>
          
          <p :if={@own.error} class="problem" id="own-error">{Words.error(@own.error)}</p>
           <.whats_new key="ascella" state={@whats_new["ascella"]} />
        </div>
        
        <%= if @own.kind == :manual do %>
          <div class="own-buttons">
            <.whats_new_button key="ascella" open?={Map.has_key?(@whats_new, "ascella")} />
            <a href={Updates.releases_page()} target="_blank" rel="noopener" class="btn btn-quiet">
              {gettext("How to update")}
            </a>
          </div>
        <% else %>
          <div class="own-buttons">
            <.whats_new_button key="ascella" open?={Map.has_key?(@whats_new, "ascella")} />
            <button
              id="update-self"
              class="btn btn-primary"
              phx-click="update_self"
              disabled={@own.busy? or @own.waiting?}
            >
              {if @own.busy?, do: gettext("Updating..."), else: gettext("Update Ascella")}
            </button>
          </div>
        <% end %>
      </div>
      
      <ul class="tiles" id="tiles">
        <li
          :for={tile <- @tiles}
          id={"tile-#{tile.app.id}"}
          class={["tile", tile.busy && "is-busy", tile.running? && "is-running"]}
          style={"--app-accent: #{Enum.at(tile.app.accent, 0)}; --app-accent-night: #{Enum.at(tile.app.accent, 1)}"}
        >
          <div class="tile-head">
            <.mark file={tile.app.mark} />
            <div class="tile-title">
              <h2>{tile.app.name}</h2>
              
              <p class="blurb">{Map.get(tile.app.blurb, @locale) || Map.get(tile.app.blurb, "en")}</p>
            </div>
            
            <span
              :if={tile.state == :installed}
              class={["pill", if(tile.running?, do: "pill-on", else: "pill-off")]}
              id={"state-#{tile.app.id}"}
            >
              {if tile.running?, do: gettext("Running"), else: gettext("Stopped")}
            </span>
          </div>
          
          <dl class="versions">
            <div>
              <dt>{gettext("Installed")}</dt>
              
              <dd id={"installed-#{tile.app.id}"}>
                <%= cond do %>
                  <% tile.state == :absent -> %>
                    <span class="muted">{gettext("Not installed")}</span>
                  <% tile.version -> %>
                    {tile.version}
                  <% true -> %>
                    <span class="muted">{gettext("Unknown version")}</span>
                <% end %>
              </dd>
            </div>
            
            <div>
              <dt>{gettext("Latest")}</dt>
              
              <dd id={"latest-#{tile.app.id}"}>
                <%= cond do %>
                  <% tile.latest -> %>
                    {tile.latest} <span :if={tile.update?} class="new">{gettext("new")}</span>
                  <% tile.latest_error -> %>
                    <span class="muted">{Words.latest_error(tile.latest_error)}</span>
                  <% true -> %>
                    <span class="muted">&hellip;</span>
                <% end %>
              </dd>
            </div>
          </dl>
          
          <p :if={not tile.build?} class="note">
            <%= if tile.intel_mac? do %>
              {gettext("No build for Intel Macs yet.")}
            <% else %>
              {gettext("No build for this computer.")}
            <% end %>
          </p>
          
          <p :if={tile.state == :per_machine} class="note">
            {gettext("Installed for everyone on this PC; updated with its .msi.")}
          </p>
          
          <p :if={tile.error} class="problem" id={"error-#{tile.app.id}"}>
            {Words.error(tile.error, tile.app)}
            <button
              :if={running_error?(tile.error) and tile.running? and !tile.busy}
              id={"error-stop-#{tile.app.id}"}
              class="btn"
              phx-click="act"
              phx-value-id={tile.app.id}
              phx-value-action="stop"
            >
              {gettext("Stop")}
            </button>
          </p>
          
          <p
            :if={tile.state == :installed and not tile.rollback?}
            class="note"
            id={"no-rollback-#{tile.app.id}"}
          >
            {gettext("There is no way back to an older version: updating changes its database.")}
          </p>
          
          <div
            :if={tile.state == :installed and tile.launchers != [] and !tile.busy}
            class="launchers"
            id={"launchers-#{tile.app.id}"}
          >
            <div :if={tile.offer?} class="offer" id={"offer-#{tile.app.id}"}>
              <p>{gettext("Make %{name} easy to start?", name: tile.app.name)}</p>
              
              <div class="offer-buttons">
                <button
                  id={"offer-yes-#{tile.app.id}"}
                  class="btn btn-primary"
                  phx-click="offer"
                  phx-value-id={tile.app.id}
                  phx-value-answer="yes"
                >
                  {Words.offer(@default_kinds)}
                </button>
                
                <button
                  id={"offer-no-#{tile.app.id}"}
                  class="btn btn-quiet"
                  phx-click="offer"
                  phx-value-id={tile.app.id}
                  phx-value-answer="no"
                >
                  {gettext("No thanks")}
                </button>
              </div>
            </div>
            
            <details open={tile.offer?}>
              <summary>{gettext("Shortcuts")}</summary>
              
              <label :for={opt <- tile.launchers} class="check">
                <input
                  type="checkbox"
                  id={"launcher-#{tile.app.id}-#{opt.kind}"}
                  checked={opt.on?}
                  phx-click="launcher"
                  phx-value-id={tile.app.id}
                  phx-value-kind={opt.kind}
                  phx-value-on={to_string(not opt.on?)}
                /> <span>{Words.launcher(opt.kind)}</span>
              </label>
            </details>
            
            <%= case @notes[tile.app.id] do %>
              <% :pin_taskbar -> %>
                <p class="note" id={"note-#{tile.app.id}"}>
                  {gettext(
                    "To pin it to the taskbar: right-click it in the Start menu, then Pin to taskbar."
                  )}
                  <button
                    id={"reveal-#{tile.app.id}"}
                    class="btn btn-quiet"
                    phx-click="reveal"
                    phx-value-id={tile.app.id}
                    phx-value-kind="start_menu"
                  >
                    {gettext("Show the shortcut")}
                  </button>
                </p>
              <% {:error, reason} -> %>
                <p class="problem" id={"note-#{tile.app.id}"}>{Words.reason(reason)}</p>
              <% _none -> %>
            <% end %>
          </div>
          
          <div
            :if={@removing == tile.app.id}
            class="remove-panel"
            id={"remove-panel-#{tile.app.id}"}
          >
            <%= if @confirm_data == tile.app.id do %>
              <p class="problem">
                {gettext(
                  "Last check. This deletes the data of %{name} for good: tournaments, games, settings. There is no Bin for it.",
                  name: tile.app.name
                )}
              </p>
              
              <div class="offer-buttons">
                <button
                  id={"remove-data-yes-#{tile.app.id}"}
                  class="btn btn-danger"
                  phx-click="remove_with_data"
                  phx-value-id={tile.app.id}
                >
                  {gettext("Remove it and delete the data")}
                </button>
                
                <button
                  id={"remove-cancel-#{tile.app.id}"}
                  class="btn btn-quiet"
                  phx-click="remove_cancel"
                >
                  {gettext("Cancel")}
                </button>
              </div>
            <% else %>
              <p>
                {gettext(
                  "Remove %{name}? It is stopped first, and the shortcuts Ascella made for it go too. Its data (tournaments, games, settings) is kept in its own folders, outside the program, so removing it takes none of that.",
                  name: tile.app.name
                )}
              </p>
              
              <.form
                for={to_form(%{}, as: :remove)}
                id={"remove-form-#{tile.app.id}"}
                phx-submit="remove"
              >
                <input type="hidden" name="app_id" value={tile.app.id} />
                <label class="check">
                  <input
                    type="checkbox"
                    name="delete_data"
                    value="true"
                    id={"delete-data-#{tile.app.id}"}
                  /> <span>{gettext("Also delete its data")}</span>
                </label>
                
                <div class="offer-buttons">
                  <button id={"remove-yes-#{tile.app.id}"} type="submit" class="btn">
                    {gettext("Remove")}
                  </button>
                  
                  <button
                    id={"remove-cancel-#{tile.app.id}"}
                    type="button"
                    class="btn btn-quiet"
                    phx-click="remove_cancel"
                  >
                    {gettext("Cancel")}
                  </button>
                </div>
              </.form>
            <% end %>
          </div>
          
          <.whats_new
            :if={tile.update? and tile.state == :installed and !tile.busy}
            key={tile.app.id}
            state={@whats_new[tile.app.id]}
          />
          <div class="tile-actions">
            <%= if tile.busy do %>
              <span class="busy" id={"busy-#{tile.app.id}"}>
                <span class="spinner" aria-hidden="true"></span> {Words.action(tile.busy)}&hellip;
              </span>
            <% else %>
              <button
                :if={tile.build? and tile.state == :absent}
                id={"install-#{tile.app.id}"}
                class="btn btn-primary"
                phx-click="act"
                phx-value-id={tile.app.id}
                phx-value-action="install"
                disabled={is_nil(tile.latest)}
              >
                {gettext("Install")}
              </button>
              
              <.whats_new_button
                :if={tile.update? and tile.state == :installed}
                key={tile.app.id}
                open?={Map.has_key?(@whats_new, tile.app.id)}
              />
              <button
                :if={tile.update? and tile.state == :installed}
                id={"update-#{tile.app.id}"}
                class="btn btn-primary"
                phx-click="act"
                phx-value-id={tile.app.id}
                phx-value-action="update"
              >
                {gettext("Update to %{version}", version: tile.latest)}
              </button>
              
              <button
                :if={tile.state != :absent and not tile.running?}
                id={"start-#{tile.app.id}"}
                class="btn"
                phx-click="act"
                phx-value-id={tile.app.id}
                phx-value-action="start"
              >
                {gettext("Start")}
              </button>
              
              <button
                :if={tile.running?}
                id={"stop-#{tile.app.id}"}
                class="btn"
                phx-click="act"
                phx-value-id={tile.app.id}
                phx-value-action="stop"
              >
                {gettext("Stop")}
              </button>
              
              <a
                :if={tile.running? and tile.app.port}
                id={"open-#{tile.app.id}"}
                class="btn"
                href={"http://localhost:#{tile.app.port}"}
                target="_blank"
                rel="noopener"
              >
                {gettext("Open")}
              </a>
              
              <button
                :if={tile.state == :installed and @removing != tile.app.id}
                id={"remove-#{tile.app.id}"}
                class="btn btn-quiet"
                phx-click="remove_ask"
                phx-value-id={tile.app.id}
              >
                {gettext("Remove")}
              </button>
              
              <button
                :if={tile.previous && tile.rollback?}
                id={"rollback-#{tile.app.id}"}
                class="btn btn-quiet"
                phx-click="act"
                phx-value-id={tile.app.id}
                phx-value-action="rollback"
                data-confirm={gettext("Go back to %{version}?", version: tile.previous)}
              >
                {gettext("Back to %{version}", version: tile.previous)}
              </button>
            <% end %>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  attr :key, :string, required: true
  attr :open?, :boolean, required: true

  defp whats_new_button(assigns) do
    ~H"""
    <button
      id={"whats-new-#{@key}"}
      class="btn btn-quiet"
      phx-click="whats_new"
      phx-value-id={@key}
      aria-expanded={to_string(@open?)}
      aria-controls={"whats-new-panel-#{@key}"}
    >
      {gettext("What's new")}
    </button>
    """
  end

  attr :key, :string, required: true
  attr :state, :any, default: nil

  defp whats_new(assigns) do
    ~H"""
    <div :if={@state} id={"whats-new-panel-#{@key}"} class="whats-new">
      <%= case @state do %>
        <% :loading -> %>
          <p class="busy" id={"whats-new-loading-#{@key}"}>
            <span class="spinner" aria-hidden="true"></span> {gettext("Reading the release notes")}&hellip;
          </p>
        <% {:error, _reason} -> %>
          <p class="problem" id={"whats-new-error-#{@key}"}>
            {gettext(
              "The release notes could not be fetched from GitHub. The update works without them."
            )}
          </p>
        <% {:ok, []} -> %>
          <p class="note" id={"whats-new-empty-#{@key}"}>
            {gettext("GitHub has no notes for this update.")}
          </p>
        <% {:ok, releases} -> %>
          <section :for={release <- releases} id={"whats-new-#{@key}-#{release.version}"}>
            <h3>{release.version}</h3>
             <ReleaseNotes.notes body={release.body} />
          </section>
      <% end %>
    </div>
    """
  end

  defp running_error?({_action, {:running, _name}}), do: true
  defp running_error?(_other), do: false

  attr :file, :string, required: true

  defp mark(assigns) do
    assigns = assign(assigns, :mark, Logo.app_mark(assigns.file))

    ~H"""
    <svg :if={@mark} class="tile-mark" viewBox={elem(@mark, 0)} aria-hidden="true">
      {Phoenix.HTML.raw(elem(@mark, 1))}
    </svg>
     <span :if={!@mark} class="tile-mark tile-mark-none" aria-hidden="true"></span>
    """
  end
end
