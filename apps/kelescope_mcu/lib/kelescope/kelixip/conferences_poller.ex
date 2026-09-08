defmodule Kelescope.Kelixip.ConferencesPoller do
  @moduledoc """
  Polls `Kelix.Control.module_command/3` (`"mcu"`, `"conference.list"`) on the
  monitored kelixip node and republishes the result via `Phoenix.PubSub` on
  `"kelixip:conferences"`. Like `StatusPoller`, and unlike scenario monitoring or
  domain counters, kelixip's `mcu` module delivers no live push for conferences
  today (DESIGN-MCU.md §11: MCU events are only logged and metered, never
  delivered to an external consumer) — kelescope polls on a timer instead.
  """
  use GenServer
  require Logger

  @conferences_topic "kelixip:conferences"
  @poll_interval 10_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Last conference list successfully polled, or `nil` before the first poll completes."
  @spec snapshot(GenServer.server()) :: [map()] | nil
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    cookie = Keyword.get(opts, :cookie)
    if cookie, do: Node.set_cookie(node, String.to_atom(cookie))
    send(self(), :poll)

    {:ok,
     %{
       node: node,
       interval: Keyword.get(opts, :poll_interval, @poll_interval),
       topic: Keyword.get(opts, :conferences_topic, @conferences_topic),
       conferences: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.conferences, state}

  @impl true
  def handle_info(:poll, state) do
    new_state =
      case Kelescope.Kelixip.Control.list_conferences(state.node) do
        {:ok, conferences} ->
          Phoenix.PubSub.broadcast(
            Kelescope.PubSub,
            state.topic,
            {:kelixip_conferences, conferences}
          )

          %{state | conferences: conferences}

        {:error, reason} ->
          Logger.warning("kelixip conferences poll to #{state.node}: #{inspect(reason)}")
          state
      end

    Process.send_after(self(), :poll, state.interval)
    {:noreply, new_state}
  end
end
