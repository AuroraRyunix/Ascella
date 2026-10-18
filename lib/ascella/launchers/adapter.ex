defmodule Ascella.Launchers.Adapter do
  @moduledoc """
  What differs per system when an app is made easy to start. One module per
  system (`Windows`, `MacOS`, `Linux`); `Ascella.Launchers` picks by the
  context's family and keeps the record of what was made.

  Everything here goes through the context: base folders are its fields and
  commands run through its runner, so a test hands it a temporary folder and
  a fake runner and the real Start menu, Dock and gsettings stay untouched.

  `target` is what the launcher starts: `%{exec, args, workdir, icon, url,
  bundle}`, see `Ascella.Launchers.target/2`. A `record` is the map kept for
  one thing that was made: `"path"`, `"file"` (true when it is a file Ascella
  may delete itself) and whatever else its removal needs.
  """

  alias Ascella.Catalogue.App
  alias Ascella.Context

  @type kind :: atom
  @type launcher_record :: %{required(String.t()) => term}

  @doc "The kinds of launcher this system can offer for this target."
  @callback kinds(Context.t(), target :: map) :: [kind]

  @doc "Makes one. `existing` is the record of an earlier one of ours (refresh), else nil."
  @callback create(kind, App.t(), target :: map, Context.t(), existing :: launcher_record | nil) ::
              {:ok, launcher_record} | {:error, term}

  @doc "Undoes what a file delete cannot (Dock, login items, favourites)."
  @callback delete(kind, App.t(), launcher_record, Context.t()) :: :ok | {:error, term}

  @doc "Is it still there? Files are looked at; a Dock is asked, through the context's runner."
  @callback exists?(kind, launcher_record, Context.t()) :: boolean

  @doc "Kinds that are files pointing at the executable, and are made again after an update."
  @callback refreshable() :: [kind]
end
