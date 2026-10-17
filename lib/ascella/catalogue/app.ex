defmodule Ascella.Catalogue.App do
  @moduledoc "One app of the catalogue."
  defstruct [:id, :name, :repo, :mark, :accent, :port, :blurb, platforms: %{}, data: %{}]
end
