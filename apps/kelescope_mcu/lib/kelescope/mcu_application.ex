defmodule Kelescope.Mcu.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Kelescope.Kelixip.ConferencesPoller,
       Application.fetch_env!(:kelescope_mcu, Kelescope.Kelixip.ConferencesPoller)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Kelescope.Mcu.Supervisor)
  end
end
