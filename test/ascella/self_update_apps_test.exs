defmodule Ascella.SelfUpdateAppsTest do
  @moduledoc """
  Ascella's own update inside `Ascella.Apps`: last in the queue, never
  while anything else is under way, and refused at the one place that knows.
  The stop that would end the VM is replaced by a message to the test.
  """
  use AscellaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ascella.{Apps, FakeGitHub, FakeRunner}

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  @own %{version: "99.0.0", tag: "v99.0.0", kind: :velopack}

  setup do
    parent = self()
    Application.put_env(:ascella, :install_kind, :velopack)

    Application.put_env(:ascella, :updates_stop_fun, fn code -> send(parent, {:stopped, code}) end)

    FakeGitHub.serve(%{})

    reset(%{own: @own})

    on_exit(fn ->
      Application.put_env(:ascella, :install_kind, :manual)
      Application.delete_env(:ascella, :updates_stop_fun)
      reset(%{})
      FakeRunner.reset()
    end)

    :ok
  end

  # The one process is shared by the whole suite: put it in the state a test
  # wants, and back to nothing afterwards.
  defp reset(overrides) do
    :sys.replace_state(Apps, fn state ->
      Map.merge(
        %{state | busy: %{}, queue: [], errors: %{}, own: nil, latest: %{}, status: %{}},
        overrides
      )
    end)
  end

  defp make_update_due do
    :sys.replace_state(Apps, fn state ->
      %{
        state
        | status: %{"hallapp" => %{state: :installed, version: "1.0.0", previous: nil}},
          latest: %{"hallapp" => {:ok, %{version: "2.0.0", tag: "v2.0.0"}}}
      }
    end)
  end

  test "an update is applied when nothing else is busy" do
    assert :ok = Apps.update_self()
    assert_receive {:stopped, 90}, 5_000
  end

  test "nothing is applied while an install is under way" do
    :sys.replace_state(Apps, fn state -> %{state | busy: %{"hallapp" => :install}} end)

    assert Apps.busy?()
    assert {:error, :busy} = Apps.update_self()
    refute_receive {:stopped, _}, 200
  end

  test "nothing is applied while an update waits its turn in the queue" do
    :sys.replace_state(Apps, fn state -> %{state | queue: ["zipapp"]} end)

    assert Apps.busy?()
    assert {:error, :busy} = Apps.update_self()
  end

  test "Ascella's own place in the queue is not 'busy'" do
    :sys.replace_state(Apps, fn state -> %{state | queue: ["ascella"]} end)
    refute Apps.busy?()
  end

  test "there is nothing to do without a newer release, or on a copy that updates by hand" do
    reset(%{own: nil})
    assert {:error, :no_update} = Apps.update_self()

    reset(%{own: %{@own | version: "0.0.1"}})
    assert {:error, :not_newer} = Apps.update_self()

    Application.put_env(:ascella, :install_kind, :manual)
    reset(%{own: %{@own | kind: :manual}})
    assert {:error, :manual} = Apps.update_self()
  end

  test "while Ascella replaces itself, no other action and no 'Update all' is started" do
    :sys.replace_state(Apps, fn state -> %{state | busy: %{"ascella" => :update_self}} end)

    assert {:error, :updating_self} = Apps.act("hallapp", :install)
    assert {:error, :updating_self} = Apps.update_all()
  end

  test "Update all does the other programs first and Ascella last" do
    make_update_due()

    assert {:ok, ["hallapp", "ascella"]} = Apps.update_all()

    # hallapp is under way (and, with no GitHub to download from, fails);
    # Ascella is still waiting for it, not started.
    state = :sys.get_state(Apps)
    assert "ascella" in state.queue or state.errors["hallapp"] != nil

    assert_receive {:stopped, 90}, 5_000

    # By the time Ascella started, the app before it was over - and had its say.
    state = :sys.get_state(Apps)
    assert {:update, _reason} = state.errors["hallapp"]
    assert state.queue == []
  end

  test "Update all with only Ascella to update updates Ascella" do
    assert {:ok, ["ascella"]} = Apps.update_all()
    assert_receive {:stopped, 90}, 5_000
  end

  test "Update all leaves a hand-updated copy out of the list" do
    Application.put_env(:ascella, :install_kind, :manual)
    reset(%{own: %{@own | kind: :manual}})
    assert {:ok, []} = Apps.update_all()
  end

  test "the page offers the update, and says it is waiting when it is", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    send(view.pid, :apps_changed)

    assert render(view) =~ "99.0.0"
    assert has_element?(view, "#own-update #update-self:not([disabled])")

    :sys.replace_state(Apps, fn state -> %{state | queue: ["zipapp", "ascella"]} end)
    send(view.pid, :apps_changed)
    # Queued behind another program: shown as waiting, and the button is off.
    assert has_element?(view, "#own-waiting")
    assert has_element?(view, "#update-self[disabled]")
  end

  test "pressing the button while something is busy says so on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    :sys.replace_state(Apps, fn state -> %{state | busy: %{"hallapp" => :install}} end)

    html = view |> element("#update-self") |> render_click()
    assert html =~ "busy"
    refute_receive {:stopped, _}, 200
  end
end
