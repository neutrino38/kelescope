defmodule Kelescope.Boot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Kelescope.Boot.Starter],
      strategy: :one_for_one,
      name: Kelescope.Boot.Supervisor
    )
  end
end
