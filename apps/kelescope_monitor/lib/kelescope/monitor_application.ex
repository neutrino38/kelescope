defmodule Kelescope.Monitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Kelescope.Kelixip.StatusPoller,
       Application.fetch_env!(:kelescope_monitor, Kelescope.Kelixip.StatusPoller)},
      {Kelescope.Kelixip.AuthDbPoller,
       Application.fetch_env!(:kelescope_monitor, Kelescope.Kelixip.AuthDbPoller)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Kelescope.Monitor.Supervisor)
  end
end
