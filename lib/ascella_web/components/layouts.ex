defmodule AscellaWeb.Layouts do
  @moduledoc """
  The page around every page: the mark, the name, the language switch, and
  the flash messages. One header, because there is one page and a help.
  """
  use AscellaWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :locale, :string, default: "en"
  attr :path, :string, default: "/"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <header class="masthead">
        <a href={~p"/"} class="brand" id="brand">
          <svg class="brand-mark" viewBox="0 0 24 24" aria-hidden="true">
            {Phoenix.HTML.raw(AscellaWeb.Logo.inner())}
          </svg>
          <span class="brand-name">Ascella</span>
          <span class="brand-version">{Application.spec(:ascella, :vsn)}</span>
        </a>
        <nav class="masthead-nav">
          <a href={~p"/help"} id="help-link">{gettext("Help")}</a>
          <span class="lang" id="lang-switch">
            <a href={"#{@path}?lang=en"} class={[@locale == "en" && "on"]} hreflang="en">EN</a>
            <a href={"#{@path}?lang=nl"} class={[@locale == "nl" && "on"]} hreflang="nl">NL</a>
          </span>
        </nav>
      </header>
      <main class="content">
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="flashes">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("No connection")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Trying again")}
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Ascella stopped answering")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Trying again")}
      </.flash>
    </div>
    """
  end
end
