defmodule Kelescope.Boot.Starter do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}, {:continue, :load_plugins}}

  @impl true
  def handle_continue(:load_plugins, state) do
    case load() do
      {:ok, []} ->
        {:noreply, state}

      {:ok, apps} ->
        Logger.info("kelescope: applications chargées #{inspect(apps)}")
        {:noreply, state}

      {:error, message} ->
        Logger.error("kelescope: #{message}")
        System.stop(1)
        {:noreply, state}
    end
  end

  defp load do
    {:ok, Kelescope.Boot.Loader.load_all()}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
