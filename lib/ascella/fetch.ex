defmodule Ascella.Fetch do
  @moduledoc """
  What a release is, and getting its files - from GitHub, over HTTPS, and
  from nowhere else.

  ## Where from

  The latest release of an app is asked of `api.github.com` for the
  repository in the catalogue. Its files are then fetched from
  `https://github.com/<repo>/releases/download/<tag>/<name>`, an address
  built here from the catalogue and the tag - never one taken out of an
  answer - and the redirects GitHub answers with are followed by hand, only
  over HTTPS and only to GitHub's own hosts (`@hosts`). A redirect anywhere
  else is a failed download, not an adventure.

  ## Verified, or not used

  Every release this program installs from publishes `SHA256SUMS`. A file
  is kept only when its SHA-256 is the one listed there for its name; a
  release without the list, or a file that is not on it, is refused, and the
  half-downloaded file goes with the refusal. Nothing that came out of
  `download/5` without `{:ok, ...}` is ever unpacked or started.

  What this catches: a download that broke, a proxy that "helped", a file
  swapped on the way. What it does not: a release that was bad when it was
  published, since the list comes from the same release. That needs
  signatures, and none of these apps signs anything yet.
  """

  @api "https://api.github.com"
  @hosts ~w(github.com objects.githubusercontent.com release-assets.githubusercontent.com)
  @max_redirects 5
  @user_agent "Ascella"

  @doc """
  The latest published release of `repo`: `{:ok, %{version, tag, assets}}`
  with `assets` a map of name to size, `{:error, :no_release}`, or
  `{:error, reason}` (offline, rate limited, an answer that makes no sense).
  """
  def latest(repo, req_options \\ []) do
    request =
      [
        url: "#{@api}/repos/#{repo}/releases/latest",
        headers: [{"accept", "application/vnd.github+json"}, {"user-agent", @user_agent}],
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(req_options)

    case Req.get(Req.new(request)) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag} = release}} ->
        read_release(tag, release)

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_release}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:offline, reason}}
    end
  end

  defp read_release(tag, release) do
    with false <- release["draft"] == true or release["prerelease"] == true,
         tag when is_binary(tag) <- tag,
         {:ok, version} <- Version.parse(String.trim_leading(tag, "v")),
         true <- tag =~ ~r/\Av?[0-9]+\.[0-9]+\.[0-9]+\z/ do
      assets =
        for %{"name" => name} = asset <- release["assets"] || [], is_binary(name), into: %{} do
          {name, asset["size"]}
        end

      {:ok, %{version: to_string(version), tag: tag, assets: assets}}
    else
      _unusable -> {:error, :unreadable_release}
    end
  end

  @doc """
  Downloads `name` from release `tag` of `repo` into `dir`, and keeps it
  only if `SHA256SUMS` of the same release vouches for it.

  `{:ok, %{path, sha256}}`, or `{:error, reason}` with nothing left behind:
  `:no_checksums` (the release publishes none), `:not_in_checksums`,
  `{:checksum_mismatch, expected, actual}`, `{:redirect_refused, url}`, or
  a transport error.
  """
  def download(repo, tag, name, dir, req_options \\ []) do
    base = "https://github.com/#{repo}/releases/download/#{tag}"
    sums_path = Path.join(dir, "SHA256SUMS")
    path = Path.join(dir, name)
    part = path <> ".part"

    File.mkdir_p!(dir)

    result =
      with :ok <- get_to_file("#{base}/SHA256SUMS", sums_path, req_options, :no_checksums),
           {:ok, expected} <- expected_sum(sums_path, name),
           :ok <- get_to_file("#{base}/#{name}", part, req_options, :not_found),
           actual = sha256(part),
           :ok <- same(expected, actual),
           :ok <- File.rename(part, path) do
        {:ok, %{path: path, sha256: actual}}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        File.rm(part)
        File.rm(path)
        error
    end
  end

  @doc "Whether the file at `path` still has the SHA-256 it was verified with. Asked again just before it is run."
  def still?(path, sha256), do: File.regular?(path) and sha256(path) == sha256

  @doc "The SHA-256 of a file, in lower-case hex."
  def sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Reads `SHA256SUMS` text into a map of name to sum (`sha256sum`'s two formats)."
  def parse_sums(text) do
    for line <- String.split(text, ~r/\r?\n/, trim: true),
        [_, sum, name] <- [
          Regex.run(~r/\A([0-9a-fA-F]{64}) [ *](.+)\z/, String.trim_trailing(line))
        ],
        into: %{} do
      {name, String.downcase(sum)}
    end
  end

  defp expected_sum(sums_path, name) do
    case sums_path |> File.read!() |> parse_sums() |> Map.fetch(name) do
      {:ok, sum} -> {:ok, sum}
      :error -> {:error, :not_in_checksums}
    end
  end

  defp same(sum, sum), do: :ok
  defp same(expected, actual), do: {:error, {:checksum_mismatch, expected, actual}}

  # Redirects by hand: `redirect: false`, and each Location checked before it
  # is asked. Every hop writes the file from the start, so a redirect's own
  # little body never ends up in front of the real one.
  defp get_to_file(url, path, req_options, missing, hops \\ 0)

  defp get_to_file(url, _path, _req_options, _missing, hops) when hops > @max_redirects,
    do: {:error, {:redirect_refused, url}}

  defp get_to_file(url, path, req_options, missing, hops) do
    with :ok <- allowed(url) do
      request =
        [
          url: url,
          headers: [{"user-agent", @user_agent}],
          redirect: false,
          decode_body: false,
          receive_timeout: 60_000,
          retry: false,
          into: File.stream!(path)
        ]
        |> Keyword.merge(req_options)

      case Req.get(Req.new(request)) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        {:ok, %Req.Response{status: status} = response}
        when status in [301, 302, 303, 307, 308] ->
          case Req.Response.get_header(response, "location") do
            [location | _] ->
              next = URI.merge(URI.parse(url), location) |> URI.to_string()
              get_to_file(next, path, req_options, missing, hops + 1)

            [] ->
              {:error, {:http, status}}
          end

        {:ok, %Req.Response{status: 404}} ->
          {:error, missing}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http, status}}

        {:error, reason} ->
          {:error, {:offline, reason}}
      end
    end
  end

  @doc false
  def allowed(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when host in @hosts -> :ok
      _other -> {:error, {:redirect_refused, url}}
    end
  end
end
