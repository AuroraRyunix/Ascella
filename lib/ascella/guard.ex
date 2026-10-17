defmodule Ascella.Guard do
  @moduledoc """
  The rule this whole program is built around: an update never touches an
  app's data.

  Once, an installer of a sister program was packed under an id that was
  also the name of its data folder, and an uninstall removed every
  tournament on the machine. Nobody meant to. Nobody ever means to. So
  instead of meaning not to, Ascella checks: every path it is about to
  create, write, move or delete goes through `check/2` first (by way of
  `Ascella.Fs`), and a path that is a data directory, lies inside one, or
  contains one is refused - before anything happens, with the app's name and
  the directory in the refusal.

  The protected directories are every app's, not only the one being
  updated: an OpenPairings update has no business near Alnasl's data either.
  """

  alias Ascella.{Catalogue, Context}

  @doc "Every data directory of every app in the catalogue, for this context's system."
  def protected(%Context{} = ctx, apps \\ Catalogue.apps()) do
    apps
    |> Enum.flat_map(fn app -> app |> data_dirs(ctx) |> Enum.map(&{app.id, &1}) end)
    |> Enum.uniq()
  end

  @doc "The data directories of one app, expanded for the context."
  def data_dirs(app, %Context{} = ctx) do
    app.data
    |> Map.get(ctx.family, [])
    |> Enum.flat_map(&expand(&1, ctx))
  end

  defp expand("{localappdata}" <> rest, %Context{local_app_data: dir}) when is_binary(dir),
    do: [Path.join(dir, rest)]

  defp expand("{localappdata}" <> _rest, _ctx), do: []

  defp expand("{home}" <> rest, %Context{homes: homes, home: home}) do
    for h <- Enum.uniq([home | homes]), is_binary(h) and h != "", do: Path.join(h, rest)
  end

  defp expand("/" <> _ = absolute, %Context{family: :linux} = ctx),
    do: [Context.linux_path(ctx, absolute)]

  defp expand(other, _ctx), do: [other]

  @doc """
  `:ok`, or `{:error, {:data_dir, app_id, dir}}` when `path` is a protected
  directory, is inside one, or contains one.
  """
  def check(path, %Context{} = ctx, apps \\ Catalogue.apps()) do
    target = segments(path, ctx)

    case Enum.find(protected(ctx, apps), fn {_id, dir} ->
           overlaps?(target, segments(dir, ctx))
         end) do
      nil -> :ok
      {id, dir} -> {:error, {:data_dir, id, dir}}
    end
  end

  @doc "As `check/3`, raising. For the places where a refusal is a bug, not a situation."
  def check!(path, ctx, apps \\ Catalogue.apps()) do
    case check(path, ctx, apps) do
      :ok ->
        :ok

      {:error, {:data_dir, id, dir}} ->
        raise Ascella.Guard.Refused, path: path, app: id, dir: dir
    end
  end

  defp overlaps?(_a, []), do: false
  defp overlaps?(a, b), do: List.starts_with?(a, b) or List.starts_with?(b, a)

  # Compared on whole segments, without case on Windows and macOS (both
  # file systems shrug at case by default) and with either slash. A rule a
  # capital letter can walk round is a suggestion.
  defp segments(path, %Context{family: family}) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> Path.expand()
    |> then(&if family == :linux, do: &1, else: String.downcase(&1))
    |> String.split("/", trim: true)
  end
end
