defmodule AscellaWeb.Locale do
  @moduledoc """
  English or Dutch. `?lang=nl` (or `en`) chooses and is remembered in the
  session; without a choice the browser's first language decides. The
  live page reads the same session, so the two never disagree.
  """
  import Plug.Conn

  @locales ~w(en nl)

  def locales, do: @locales

  # --- as a plug -----------------------------------------------------------------

  def init(opts), do: opts

  def call(conn, _opts) do
    chosen = conn.params["lang"]

    locale =
      cond do
        chosen in @locales -> chosen
        get_session(conn, "locale") in @locales -> get_session(conn, "locale")
        true -> from_header(get_req_header(conn, "accept-language"))
      end

    Gettext.put_locale(AscellaWeb.Gettext, locale)

    conn
    |> put_session("locale", locale)
    |> assign(:locale, locale)
  end

  defp from_header([header | _]) do
    first = header |> String.split(",") |> List.first("") |> String.trim() |> String.downcase()
    if String.starts_with?(first, "nl"), do: "nl", else: "en"
  end

  defp from_header([]), do: "en"

  # --- in a live view --------------------------------------------------------------

  def on_mount(:default, _params, session, socket) do
    locale = if session["locale"] in @locales, do: session["locale"], else: "en"
    Gettext.put_locale(AscellaWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end
end
