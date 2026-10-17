defmodule Ascella.FakeGitHub do
  @moduledoc """
  GitHub, played by a `Req.Test` stub. `serve/1` takes releases -
  `%{repo => %{version: "1.2.0", files: %{name => binary}}}` - and answers
  the API's "latest release" and the download addresses, redirecting each
  download to `release-assets.githubusercontent.com` the way the real one
  does, so the redirect checks are exercised too. `SHA256SUMS` is computed
  from the files unless the release says `sums: text` or `sums: :none`.
  """
  import Plug.Conn

  def serve(releases) do
    Req.Test.stub(Ascella.GitHub, fn conn -> answer(conn, releases) end)
  end

  defp answer(%Plug.Conn{host: "api.github.com", request_path: path} = conn, releases) do
    case Regex.run(~r{\A/repos/(.+)/releases/latest\z}, path) do
      [_, repo] ->
        case Map.get(releases, repo) do
          nil ->
            send_resp(conn, 404, ~s({"message":"Not Found"}))

          release ->
            assets =
              for {name, body} <- files(release), do: %{"name" => name, "size" => byte_size(body)}

            Req.Test.json(conn, %{
              "tag_name" => "v" <> release.version,
              "draft" => false,
              "prerelease" => false,
              "assets" => assets
            })
        end

      nil ->
        send_resp(conn, 404, "")
    end
  end

  defp answer(%Plug.Conn{host: "github.com", request_path: path} = conn, _releases) do
    conn
    |> put_resp_header("location", "https://release-assets.githubusercontent.com" <> path)
    |> send_resp(302, "redirected")
  end

  defp answer(
         %Plug.Conn{host: "release-assets.githubusercontent.com", request_path: path} = conn,
         releases
       ) do
    with [_, repo, version, name] <-
           Regex.run(~r{\A/(.+)/releases/download/v([^/]+)/([^/]+)\z}, path),
         %{version: ^version} = release <- Map.get(releases, repo),
         {:ok, body} <- Map.fetch(files(release), name) do
      send_resp(conn, 200, body)
    else
      _missing -> send_resp(conn, 404, "")
    end
  end

  defp answer(conn, _releases), do: send_resp(conn, 418, "not GitHub")

  # The release's files, with SHA256SUMS as the release would publish it.
  defp files(release) do
    files = Map.get(release, :files, %{})

    case Map.get(release, :sums, :computed) do
      :none -> files
      :computed -> Map.put(files, "SHA256SUMS", sums(files))
      text when is_binary(text) -> Map.put(files, "SHA256SUMS", text)
    end
  end

  def sums(files) do
    Enum.map_join(files, "", fn {name, body} ->
      Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> "  " <> name <> "\n"
    end)
  end

  # --- building release files ---------------------------------------------------

  @doc "A zip in memory: `[{path, content}]`."
  def zip(entries) do
    {:ok, {_name, binary}} =
      :zip.create(~c"fake.zip", Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end), [
        :memory
      ])

    binary
  end

  @doc "A .tar.gz in memory: `[{path, content}]`."
  def tar_gz(entries) do
    path =
      Path.join(System.tmp_dir!(), "ascella-fake-#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end),
        [:compressed]
      )

    binary = File.read!(path)
    File.rm!(path)
    binary
  end

  @doc "An Info.plist as the apps' build_app.sh leaves it."
  def plist(version) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>CFBundleShortVersionString</key>
      <string>#{version}</string>
    </dict></plist>
    """
  end
end
