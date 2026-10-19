defmodule AscellaWeb.ReleaseNotes do
  @moduledoc """
  Release notes from GitHub, made showable without trusting them.

  The text is somebody else's, so nothing of it is ever HTML. `parse/1`
  reads a small subset of Markdown into plain data - paragraphs and bullet
  lists made of text, **bold**, `code` and links - and `notes/1` draws that
  data with HEEx, which escapes every string. Whatever is not in the subset
  stays text, asterisks and angle brackets included. A link is a link only
  when its address is `https` with a host; any other becomes its own text.
  """
  use Phoenix.Component

  @inline ~r/(\*\*[^*\n]+\*\*|`[^`\n]+`|\[[^\]\n]+\]\([^)\s]+\))/

  @doc "Markdown text to blocks: `{:p, inlines}` and `{:ul, [inlines]}`; an inline is `{:text | :bold | :code, text}` or `{:link, text, url}`."
  def parse(body) when is_binary(body) do
    {blocks, _open?} =
      body
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], false}, &line/2)

    blocks
    |> Enum.reverse()
    |> Enum.map(fn
      {:ul, items} -> {:ul, items |> Enum.reverse() |> Enum.map(&join_inlines/1)}
      {:p, lines} -> {:p, join_inlines(lines)}
    end)
  end

  def parse(_other), do: []

  defp join_inlines(lines), do: lines |> Enum.reverse() |> Enum.join(" ") |> inlines()

  # Blocks come newest first; a paragraph is its lines, a list its bullets,
  # each bullet its lines (newest first too). `open?` is false after a blank line.
  defp line(raw, {acc, open?}) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {acc, false}

      String.starts_with?(trimmed, ["- ", "* "]) ->
        item = [trimmed |> String.slice(2..-1//1) |> String.trim()]

        case acc do
          [{:ul, items} | rest] when open? -> {[{:ul, [item | items]} | rest], true}
          _other -> {[{:ul, [item]} | acc], true}
        end

      # An indented line under a bullet goes on with it.
      String.starts_with?(raw, [" ", "\t"]) and open? and match?([{:ul, _} | _], acc) ->
        [{:ul, [item | items]} | rest] = acc
        {[{:ul, [[trimmed | item] | items]} | rest], true}

      true ->
        case acc do
          [{:p, lines} | rest] when open? -> {[{:p, [trimmed | lines]} | rest], true}
          _other -> {[{:p, [trimmed]} | acc], true}
        end
    end
  end

  defp inlines(text) do
    @inline
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&piece/1)
  end

  defp piece("**" <> _ = piece), do: {:bold, String.slice(piece, 2..-3//1)}
  defp piece("`" <> _ = piece), do: {:code, String.slice(piece, 1..-2//1)}

  defp piece("[" <> _ = piece) do
    with [_, label, url] <- Regex.run(~r/\A\[([^\]]+)\]\(([^)\s]+)\)\z/, piece),
         %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" <-
           URI.parse(url) do
      {:link, label, url}
    else
      _plain -> {:text, piece}
    end
  end

  defp piece(piece), do: {:text, piece}

  attr :body, :string, required: true
  attr :rest, :global

  @doc "The notes as HTML, every string escaped."
  def notes(assigns) do
    assigns = assign(assigns, :blocks, parse(assigns.body))

    ~H"""
    <div class="release-notes" {@rest}>
      <%= for block <- @blocks do %>
        <%= case block do %>
          <% {:ul, items} -> %>
            <ul>
              <li :for={item <- items}><.inline :for={part <- item} part={part} /></li>
            </ul>
          <% {:p, parts} -> %>
            <p><.inline :for={part <- parts} part={part} /></p>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :part, :any, required: true

  defp inline(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp inline(%{part: {:bold, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"<strong>{@text}</strong>"
  end

  defp inline(%{part: {:code, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"<code>{@text}</code>"
  end

  defp inline(%{part: {:link, text, url}} = assigns) do
    assigns = assign(assigns, text: text, url: url)
    ~H|<a href={@url} target="_blank" rel="noopener">{@text}</a>|
  end
end
