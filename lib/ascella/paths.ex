defmodule Ascella.Paths do
  @moduledoc """
  Where Ascella keeps its own things: one directory (`config :ascella,
  :data_dir`, `ASCELLA_DATA`). The downloads it has verified, the copies of
  programs it put in place itself (a portable zip, a Linux zip), and the
  request file for its own update. Never any managed app's data: those
  belong to the apps, and `Ascella.Guard` keeps it that way.
  """

  def data, do: ensure(Application.fetch_env!(:ascella, :data_dir))
  def downloads, do: ensure(Path.join(data(), "downloads"))

  @doc "Where Ascella unpacks programs that have no installer of their own here."
  def programs do
    case Application.get_env(:ascella, :programs_dir) do
      nil -> ensure(Path.join(data(), "programs"))
      dir -> ensure(dir)
    end
  end

  defp ensure(dir) do
    File.mkdir_p!(dir)
    dir
  end
end
