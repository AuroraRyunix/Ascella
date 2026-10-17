defmodule Ascella.Guard.Refused do
  defexception [:path, :app, :dir]

  @impl true
  def message(%{path: path, app: app, dir: dir}),
    do: "refused to touch #{path}: it overlaps #{dir}, the data of #{app}"
end
