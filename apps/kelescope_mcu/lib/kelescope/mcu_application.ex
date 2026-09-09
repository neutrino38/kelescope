defmodule Kelescope.Mcu.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Kelescope.Kelixip.ConferencesLink,
       Application.fetch_env!(:kelescope_mcu, Kelescope.Kelixip.ConferencesLink)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Kelescope.Mcu.Supervisor)
  end
end
