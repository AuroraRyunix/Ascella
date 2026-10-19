defmodule AscellaWeb.WhatsNewTest do
  @moduledoc "The What's new control beside an offered update, and what it shows."
  use AscellaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ascella.{Apps, FakeGitHub, FakeRunner}

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  setup do
    Application.put_env(:ascella, :install_kind, :velopack)

    :sys.replace_state(Apps, fn state ->
      %{
        state
        | busy: %{},
          queue: [],
          errors: %{},
          own: %{version: "99.0.0", tag: "v99.0.0", kind: :velopack},
          status: %{"hallapp" => %{state: :installed, version: "1.0.0", previous: nil}},
          latest: %{"hallapp" => {:ok, %{version: "2.0.0", tag: "v2.0.0"}}}
      }
    end)

    on_exit(fn ->
      Application.put_env(:ascella, :install_kind, :manual)

      :sys.replace_state(Apps, fn state ->
        %{state | busy: %{}, queue: [], errors: %{}, own: nil, latest: %{}, status: %{}}
      end)

      FakeRunner.reset()
    end)

    :ok
  end

  defp release(version, body), do: %{version: version, body: body}

  test "beside an offered update, it shows the notes of every version in between", %{conn: conn} do
    FakeGitHub.serve(%{
      "Example/Hallapp" => %{
        version: "2.0.0",
        history: [
          release("2.0.0", "- [Feature] **Newest.** See [docs](https://example.com)."),
          release("1.5.0", "- [Fix] **Middle.** `code`"),
          release("1.0.0", "- [Fix] **Already installed.**")
        ]
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#update-hallapp")
    assert has_element?(view, "#whats-new-hallapp")
    refute has_element?(view, "#whats-new-panel-hallapp")

    view |> element("#whats-new-hallapp") |> render_click()
    assert has_element?(view, "#whats-new-panel-hallapp")

    html = render_async(view)
    assert has_element?(view, "#whats-new-hallapp-2\\.0\\.0 strong", "Newest.")
    assert has_element?(view, "#whats-new-hallapp-1\\.5\\.0 code", "code")
    refute has_element?(view, "#whats-new-hallapp-1\\.0\\.0")
    assert html =~ ~s(href="https://example.com")

    # A second press closes it, and the update button was there all along.
    view |> element("#whats-new-hallapp") |> render_click()
    refute has_element?(view, "#whats-new-panel-hallapp")
    assert has_element?(view, "#update-hallapp")
  end

  test "when GitHub cannot be reached it says so and the update stays", %{conn: conn} do
    Req.Test.stub(Ascella.GitHub, &Req.Test.transport_error(&1, :econnrefused))

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#whats-new-hallapp") |> render_click()
    assert has_element?(view, "#whats-new-loading-hallapp")

    render_async(view)
    assert has_element?(view, "#whats-new-error-hallapp")
    assert has_element?(view, "#update-hallapp:not([disabled])")
  end

  test "Ascella's own update has the control too", %{conn: conn} do
    FakeGitHub.serve(%{
      "teapot-chess/Ascella" => %{
        version: "99.0.0",
        history: [release("99.0.0", "- [Feature] **Own news.**")]
      }
    })

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#own-update #whats-new-ascella")
    assert has_element?(view, "#own-update #update-self")

    view |> element("#whats-new-ascella") |> render_click()
    render_async(view)
    assert has_element?(view, "#whats-new-ascella-99\\.0\\.0 strong", "Own news.")
  end
end
