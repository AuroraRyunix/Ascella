defmodule Ascella.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AscellaWeb.Telemetry,
      {Phoenix.PubSub, name: Ascella.PubSub},
      {Task.Supervisor, name: Ascella.TaskSupervisor},
      # What is installed, what is out, what is running.
      Ascella.Apps,
      # The launcher's Details panel: this start's secret (and its file, when
      # no launcher handed one over) and the CPU sample. Before the endpoint,
      # which asks it.
      Ascella.LauncherDetails,
      AscellaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ascella.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AscellaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
