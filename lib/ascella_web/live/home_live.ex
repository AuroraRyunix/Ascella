defmodule AscellaWeb.HomeLive do
  @moduledoc """
  The one page: a tile per app with what is installed, what is out and
  whether it runs, and the buttons that change that. Everything it shows
  comes from `Ascella.Apps`; everything it does goes there too.
  """
  use AscellaWeb, :live_view

  alias Ascella.{Apps, Updates}
  alias AscellaWeb.{Logo, Words}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Apps.subscribe()

    {:ok,
     socket
     |> assign(:own_message, nil)
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

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("update_all", _params, socket) do
    {:ok, ids} = Apps.update_all()

    socket =
      if ids == [],
        do: put_flash(socket, :info, gettext("Everything is up to date.")),
        else: socket

    {:noreply, load(socket)}
  end

  def handle_event("check", _params, socket) do
    Apps.check_now()
    {:noreply, put_flash(socket, :info, gettext("Asking GitHub."))}
  end

  def handle_event("update_self", _params, socket) do
    case Apps.own_update() do
      nil ->
        {:noreply, socket}

      update ->
        case Updates.apply(update) do
          :ok ->
            {:noreply,
             assign(
               socket,
               :own_message,
               gettext("Ascella is updating itself. This page comes back in a minute.")
             )}

          {:error, :manual} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Words.reason(reason))}
        end
    end
  end

  defp load(socket) do
    tiles = Apps.tiles()

    socket
    |> assign(:tiles, tiles)
    |> assign(:updates, Enum.count(tiles, & &1.update?))
    |> assign(:own, Apps.own_update())
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
            {gettext("Update all")}
            <span :if={@updates > 0} class="count">{@updates}</span>
          </button>
        </div>
      </section>

      <div :if={@own} id="own-update" class="own-update">
        <p>
          {gettext("Ascella %{version} is out.", version: @own.version)}
          <span :if={@own_message}>{@own_message}</span>
        </p>
        <%= if @own.kind == :manual do %>
          <a href={Updates.releases_page()} target="_blank" rel="noopener" class="btn btn-quiet">
            {gettext("How to update")}
          </a>
        <% else %>
          <button id="update-self" class="btn btn-primary" phx-click="update_self">
            {gettext("Install and restart")}
          </button>
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
                    {tile.latest}
                    <span :if={tile.update?} class="new">{gettext("new")}</span>
                  <% tile.latest_error -> %>
                    <span class="muted">{Words.latest_error(tile.latest_error)}</span>
                  <% true -> %>
                    <span class="muted">&hellip;</span>
                <% end %>
              </dd>
            </div>
          </dl>

          <p :if={not tile.build?} class="note">{gettext("No build for this computer.")}</p>
          <p :if={tile.state == :per_machine} class="note">
            {gettext("Installed for everyone on this PC; updated with its .msi.")}
          </p>
          <p :if={tile.error} class="problem" id={"error-#{tile.app.id}"}>
            {Words.error(tile.error)}
          </p>

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
                :if={tile.previous}
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
