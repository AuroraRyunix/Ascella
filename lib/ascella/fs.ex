defmodule Ascella.Fs do
  @moduledoc """
  The only way the installers change the file system. Every function asks
  `Ascella.Guard` about every path it touches first, and does nothing when
  the answer is no. There is deliberately no function here that deletes
  anything it was not told the exact name of: no globbing, no "tidy up the
  folder", no `rm -rf` of a parent because it looked empty.
  """

  alias Ascella.{Context, Guard}

  @doc "Makes a directory (and its parents)."
  def mkdir_p(path, %Context{} = ctx) do
    with :ok <- Guard.check(path, ctx), do: File.mkdir_p(path)
  end

  @doc "Moves `from` to `to`. Both are checked; a rename is two paths' worth of trouble."
  def rename(from, to, %Context{} = ctx) do
    with :ok <- Guard.check(from, ctx),
         :ok <- Guard.check(to, ctx),
         :ok <- File.mkdir_p(Path.dirname(to)) do
      File.rename(from, to)
    end
  end

  @doc "Removes exactly `path`, a file or a whole folder. Checked like everything else."
  def rm_rf(path, %Context{} = ctx) do
    with :ok <- Guard.check(path, ctx) do
      case File.rm_rf(path) do
        {:ok, _removed} -> :ok
        {:error, reason, _file} -> {:error, reason}
      end
    end
  end

  @doc "Writes a file (its folder is made first)."
  def write(path, content, %Context{} = ctx) do
    with :ok <- Guard.check(path, ctx),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end

  @doc "Unpacks a zip into `dir` with Erlang's own unzip (no executable bit; Windows does not miss it)."
  def unzip(zip, dir, %Context{} = ctx) do
    with :ok <- Guard.check(dir, ctx),
         :ok <- inside_only(zip),
         :ok <- File.mkdir_p(dir),
         {:ok, _files} <- :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(dir)) do
      :ok
    end
  end

  # A verified zip from the app's own release is still not allowed to write
  # outside the folder it is unpacked in. Belt, braces.
  defp inside_only(zip) do
    case :zip.list_dir(String.to_charlist(zip), [:names_only]) do
      {:ok, names} ->
        bad =
          Enum.find(names, fn name ->
            name = to_string(name)
            parts = name |> String.replace("\\", "/") |> String.split("/")
            String.starts_with?(name, ["/", "\\"]) or name =~ ~r/\A[A-Za-z]:/ or ".." in parts
          end)

        if bad, do: {:error, {:unsafe_zip_entry, to_string(bad)}}, else: :ok

      {:error, reason} ->
        {:error, {:bad_zip, reason}}
    end
  end
end
