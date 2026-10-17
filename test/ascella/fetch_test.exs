defmodule Ascella.FetchTest do
  use ExUnit.Case, async: false

  alias Ascella.{FakeGitHub, Fetch}

  @opts [plug: {Req.Test, Ascella.GitHub}]

  setup do
    dir = Path.expand("ascella-fetch-#{System.unique_integer([:positive])}", System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp serve(release),
    do: FakeGitHub.serve(%{"Example/App" => Map.put(release, :version, "1.0.0")})

  test "the latest release, and a download that matches its SHA256SUMS", %{dir: dir} do
    serve(%{files: %{"app.zip" => "the real thing"}})

    assert {:ok, %{version: "1.0.0", tag: "v1.0.0", assets: %{"app.zip" => 14}}} =
             Fetch.latest("Example/App", @opts)

    assert {:ok, %{path: path, sha256: sum}} =
             Fetch.download("Example/App", "v1.0.0", "app.zip", dir, @opts)

    assert File.read!(path) == "the real thing"
    assert Fetch.still?(path, sum)
    File.write!(path, "something else")
    refute Fetch.still?(path, sum)
  end

  test "a file whose sum is not the published one is refused and removed", %{dir: dir} do
    sums = FakeGitHub.sums(%{"app.zip" => "what was published"})
    serve(%{files: %{"app.zip" => "what arrived"}, sums: sums})

    assert {:error, {:checksum_mismatch, _, _}} =
             Fetch.download("Example/App", "v1.0.0", "app.zip", dir, @opts)

    assert File.ls!(dir) -- ["SHA256SUMS"] == []
  end

  test "no SHA256SUMS, or a file not on it, is no download at all", %{dir: dir} do
    serve(%{files: %{"app.zip" => "x"}, sums: :none})

    assert {:error, :no_checksums} =
             Fetch.download("Example/App", "v1.0.0", "app.zip", dir, @opts)

    serve(%{files: %{"app.zip" => "x"}, sums: FakeGitHub.sums(%{"other.zip" => "y"})})

    assert {:error, :not_in_checksums} =
             Fetch.download("Example/App", "v1.0.0", "app.zip", dir, @opts)

    refute File.exists?(Path.join(dir, "app.zip"))
  end

  test "a redirect away from GitHub, or to plain HTTP, is refused", %{dir: dir} do
    for location <- [
          "https://evil.example/app.zip",
          "http://release-assets.githubusercontent.com/app.zip"
        ] do
      Req.Test.stub(Ascella.GitHub, fn conn ->
        conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:redirect_refused, ^location}} =
               Fetch.download("Example/App", "v1.0.0", "app.zip", dir, @opts)
    end
  end

  test "a repository without releases says so" do
    FakeGitHub.serve(%{})
    assert {:error, :no_release} = Fetch.latest("Example/Nothing", @opts)
  end

  test "both of sha256sum's formats are read" do
    a = String.duplicate("a", 64)
    b = String.duplicate("B", 64)

    assert Fetch.parse_sums("#{a}  one.zip\r\n#{b} *two.exe\n") ==
             %{"one.zip" => a, "two.exe" => String.downcase(b)}
  end
end
