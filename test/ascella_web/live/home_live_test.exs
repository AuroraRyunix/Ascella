defmodule AscellaWeb.HomeLiveTest do
  use AscellaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ascella.{Apps, Context, FakeGitHub, FakeMachine, FakeRunner}

  # Ascella.Apps asks GitHub from its own tasks, not from the test.
  setup :set_req_test_to_shared

  # Every test starts on an empty machine, and Ascella.Apps has looked at it:
  # an install from the test before is not this test's business.
  setup do
    FakeRunner.reset()
    ctx = Context.current()

    for dir <- [ctx.local_app_data, ctx.downloads, ctx.programs, ctx.start_menu, ctx.launchers],
        do: File.rm_rf!(dir)

    Apps.look_now()
    _ = Apps.tiles()
    on_exit(&FakeRunner.reset/0)
    :ok
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  test "a tile per app in the catalogue, each with its buttons", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for id <- ~w(hallapp zipapp ghost) do
      assert has_element?(view, "#tile-#{id}")
      assert has_element?(view, "#install-#{id}")
      # Nothing installed, so nothing to be running or stopped.
      refute has_element?(view, "#state-#{id}")
      refute has_element?(view, "#stop-#{id}")
    end

    assert has_element?(view, "#check-now")
    assert has_element?(view, "#update-all")
  end

  test "Install downloads, verifies and installs, and the tile says so", %{conn: conn} do
    FakeMachine.start(Context.current())

    FakeGitHub.serve(%{
      "Example/Hallapp" => %{version: "2.0.0", files: %{"Hallapp-Setup.exe" => "setup"}}
    })

    Apps.subscribe()
    {:ok, view, _html} = live(conn, ~p"/")
    Apps.check_now()
    assert_receive :apps_changed, 5_000
    assert view |> element("#latest-hallapp") |> render() =~ "2.0.0"

    view |> element("#install-hallapp") |> render_click()
    wait_until_idle("hallapp")

    assert view |> element("#installed-hallapp") |> render() =~ "2.0.0"
    assert has_element?(view, "#start-hallapp")
    assert has_element?(view, "#state-hallapp")
    refute has_element?(view, "#error-hallapp")
  end

  test "the manual is there, in both languages", %{conn: conn} do
    assert conn |> get(~p"/help") |> html_response(200) =~ ~s(id="manual")
    assert build_conn() |> get(~p"/help?lang=nl") |> html_response(200) =~ ~s(lang="nl")
  end

  test "a request for another host than this machine is turned away" do
    conn = %{build_conn() | host: "hall-laptop.example"} |> get(~p"/")
    assert conn.status == 403
  end

  test "after an install shortcuts are offered; yes makes one, Remove takes app and shortcut away",
       %{conn: conn} do
    ctx = Context.current()
    FakeMachine.start(ctx)

    FakeGitHub.serve(%{
      "Example/Hallapp" => %{version: "2.0.0", files: %{"Hallapp-Setup.exe" => "setup"}}
    })

    Apps.subscribe()
    {:ok, view, _html} = live(conn, ~p"/")
    Apps.check_now()
    assert_receive :apps_changed, 5_000
    view |> element("#install-hallapp") |> render_click()
    wait_until_idle("hallapp")

    assert has_element?(view, "#offer-hallapp")
    view |> element("#offer-yes-hallapp") |> render_click()
    assert File.exists?(Path.join(ctx.start_menu, "Hallapp.lnk"))
    refute has_element?(view, "#offer-hallapp")
    assert has_element?(view, "#note-hallapp")
    assert has_element?(view, "#launcher-hallapp-start_menu[checked]")

    # The checkbox is the same switch, the other way.
    view |> element("#launcher-hallapp-start_menu") |> render_click()
    refute File.exists?(Path.join(ctx.start_menu, "Hallapp.lnk"))
    view |> element("#launcher-hallapp-start_menu") |> render_click()
    assert File.exists?(Path.join(ctx.start_menu, "Hallapp.lnk"))

    view |> element("#remove-hallapp") |> render_click()
    assert has_element?(view, "#remove-panel-hallapp")
    view |> form("#remove-form-hallapp") |> render_submit()
    wait_until_idle("hallapp")

    assert has_element?(view, "#install-hallapp")
    refute File.exists?(Path.join(ctx.start_menu, "Hallapp.lnk"))
  end

  test "deleting the data takes a second confirmation", %{conn: conn} do
    ctx = Context.current()
    FakeMachine.start(ctx)

    FakeGitHub.serve(%{
      "Example/Hallapp" => %{version: "2.0.0", files: %{"Hallapp-Setup.exe" => "setup"}}
    })

    Apps.subscribe()
    {:ok, view, _html} = live(conn, ~p"/")
    Apps.check_now()
    assert_receive :apps_changed, 5_000
    view |> element("#install-hallapp") |> render_click()
    wait_until_idle("hallapp")

    data = Path.join(ctx.local_app_data, "HallappData")
    File.mkdir_p!(data)
    File.write!(Path.join(data, "t.db"), "round five")

    view |> element("#remove-hallapp") |> render_click()
    view |> form("#remove-form-hallapp", %{"delete_data" => "true"}) |> render_submit()
    # Nothing is gone yet: the page asks again.
    assert File.exists?(Path.join(data, "t.db"))
    assert has_element?(view, "#remove-data-yes-hallapp")

    view |> element("#remove-data-yes-hallapp") |> render_click()
    wait_until_idle("hallapp")
    refute File.exists?(data)
  end

  test "the page for removing Ascella itself names all three systems", %{conn: conn} do
    html = conn |> get(~p"/remove-ascella") |> html_response(200)
    for id <- ~w(remove-windows remove-macos remove-linux), do: assert(html =~ ~s(id="#{id}"))
  end

  defp wait_until_idle(id, tries \\ 50) do
    tile = Enum.find(Apps.tiles(), &(&1.app.id == id))

    cond do
      tile.busy == nil ->
        :ok

      tries == 0 ->
        flunk("#{id} stayed busy")

      true ->
        assert_receive :apps_changed, 5_000
        wait_until_idle(id, tries - 1)
    end
  end
end
