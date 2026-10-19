defmodule AscellaWeb.ReleaseNotesTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias AscellaWeb.ReleaseNotes

  defp html(body) do
    assigns = %{body: body}
    rendered_to_string(~H"<ReleaseNotes.notes body={@body} />")
  end

  test "bullets, bold, code and https links" do
    out =
      html("""
      - [Feature] **Title.** Runs `mix test` and see [the page](https://example.com/a?b=1&c=2).
      - Second one
        goes on here.
      """)

    assert out =~ "<ul>"
    assert out =~ ~r|<strong[^>]*>Title.</strong>|
    assert out =~ ~r|<code[^>]*>mix test</code>|
    assert out =~ ~s(href="https://example.com/a?b=1&amp;c=2")
    assert out =~ ~s(target="_blank")
    assert out =~ ~s(rel="noopener")
    assert out =~ "Second one goes on here."
  end

  test "markup in the body comes out as text" do
    out = html("- <script>alert(1)</script> **<img src=x onerror=y>** `<b>`\n\n<iframe src=z>")

    refute out =~ "<script"
    refute out =~ "<img"
    refute out =~ "<iframe"
    assert out =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert out =~ ~r|<strong[^>]*>&lt;img src=x onerror=y&gt;</strong>|
  end

  test "links that are not https stay text" do
    for url <- [
          "http://example.com",
          "javascript:alert(1)",
          "data:text/html,x",
          "//evil.example",
          "https://"
        ] do
      out = html("[click](#{url})")
      refute out =~ "<a ", url
      assert out =~ "[click]("
    end
  end

  test "what is not in the subset is plain text" do
    out = html("### Heading\n\n*not italic* and __not bold__")
    assert out =~ "### Heading"
    assert out =~ "*not italic*"
    refute out =~ "<em>"
  end

  test "no body, no blocks" do
    assert ReleaseNotes.parse("") == []
    assert ReleaseNotes.parse(nil) == []
  end
end
