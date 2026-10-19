defmodule AscellaWeb.AccessTest do
  @moduledoc """
  The Linux service is root and listens on 127.0.0.1, where every process of
  the box can reach it. Its page wants the key `Ascella.Access` writes to a
  file only root and the desktop user can read; a browser that was not let in
  with that key gets a 403, and so does a LiveView socket that has no cookie.
  """
  use AscellaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ascella.Access
  alias AscellaWeb.AccessGate

  setup do
    tmp = Path.expand("ascella-access-#{System.unique_integer([:positive])}", System.tmp_dir!())
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "token")

    Application.put_env(:ascella, :access_token_file, path)
    Access.start()

    on_exit(fn ->
      Application.delete_env(:ascella, :access_token_file)
      Access.start()
      File.rm_rf!(tmp)
    end)

    {:ok, path: path, key: path |> File.read!() |> String.trim()}
  end

  test "the key is written to its file, and to nobody else's", %{path: path, key: key} do
    assert byte_size(key) >= 43
    assert Access.required?()
    assert Access.valid?(key)
    refute Access.valid?(key <> "x")
    refute Access.valid?(nil)

    if match?({:unix, _}, :os.type()) do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end
  end

  test "without the key every page is a 403, and says how to get in", %{conn: conn} do
    for path <- ["/", "/help", "/remove-ascella"] do
      conn = get(conn, path)
      assert response(conn, 403) =~ "ascella.sh open"
    end
  end

  test "a wrong key is a 403 too", %{conn: conn} do
    assert conn |> get("/?k=not-the-key") |> response(403)
    assert conn |> get("/?k=") |> response(403)
  end

  test "the key lets the browser in once: a redirect without it, and a cookie that does", %{
    conn: conn,
    key: key
  } do
    conn = get(conn, "/?k=#{key}")
    assert redirected_to(conn, 302) == "/"
    refute conn.resp_body =~ key

    conn = conn |> recycle() |> get("/help")
    assert html_response(conn, 200)

    {:ok, _view, html} = conn |> recycle() |> live("/")
    assert html =~ "Ascella"
  end

  test "a cookie from before a restart is not good any more", %{conn: conn, key: key, path: path} do
    conn = get(conn, "/?k=#{key}")
    assert redirected_to(conn, 302)
    old = recycle(conn)
    assert old |> get("/help") |> html_response(200)

    Access.start()
    refute key == path |> File.read!() |> String.trim()
    assert old |> recycle() |> get("/help") |> response(403)
  end

  test "a LiveView socket without the marker is sent away" do
    socket = %Phoenix.LiveView.Socket{}

    assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/"}}}} =
             AccessGate.on_mount(:default, %{}, %{}, socket)

    assert {:halt, _} =
             AccessGate.on_mount(:default, %{}, %{"ascella_access" => "forged"}, socket)

    assert {:cont, ^socket} =
             AccessGate.on_mount(:default, %{}, %{"ascella_access" => Access.marker()}, socket)
  end

  test "where no key is configured nothing is asked for", %{conn: conn} do
    Application.delete_env(:ascella, :access_token_file)
    Access.start()

    refute Access.required?()
    assert conn |> get("/help") |> html_response(200)
    assert {:cont, _} = AccessGate.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})
  end
end
