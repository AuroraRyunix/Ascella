defmodule AscellaWeb.Logo do
  @moduledoc """
  Ascella's mark, read from one file: `priv/logo/mark.svg`, drawn on a
  24 x 24 grid in `currentColor` with one accent, `var(--accent, ...)`. To
  change the logo, replace that file; the header, the help page and the
  favicon follow, and nothing else needs touching.

  The apps' marks are files in `priv/marks`, named by the catalogue. They
  are read when first shown and kept; they are our own files, not anything
  a visitor sent.
  """

  @source Path.expand("../../priv/logo/mark.svg", __DIR__)
  @external_resource @source

  @mark File.read!(@source)

  @night_accent "#f28b82"

  @doc "The inner markup of Ascella's mark, for an `<svg viewBox=\"0 0 24 24\">` of the caller's own."
  def inner, do: inner_of(@mark)

  @doc "The favicon: the mark in white (and the night accent) on an ink tile."
  def favicon do
    inner =
      inner()
      |> String.replace(~r/var\(--accent,\s*#[0-9a-fA-F]+\)/, @night_accent)
      |> String.replace("currentColor", "#ffffff")

    ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" rx="4" fill="#1b1b1a"/><g transform="translate(2.4 2.4) scale(.8)">#{inner}</g></svg>|
  end

  @doc "An app's mark: `{view_box, inner_markup}`, or nil when the file is not there."
  def app_mark(file) do
    key = {__MODULE__, file}

    case :persistent_term.get(key, :unread) do
      :unread ->
        mark = read_mark(file)
        :persistent_term.put(key, mark)
        mark

      mark ->
        mark
    end
  end

  defp read_mark(file) do
    path = Path.join(Application.app_dir(:ascella, "priv/marks"), file)

    with {:ok, svg} <- File.read(path),
         [_, view_box] <- Regex.run(~r/viewBox="([0-9. ]+)"/, svg) do
      {view_box, inner_of(svg)}
    else
      _missing -> nil
    end
  end

  defp inner_of(svg) do
    [_, inner] = Regex.run(~r/<svg[^>]*>(.*)<\/svg>/s, svg)
    inner
  end
end
