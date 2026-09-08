defmodule Kelescope.Kelixip.StatusPoller do
  @moduledoc """
  Polls `Kelix.Control.status/0` on the monitored kelixip node and
  republishes it via `Phoenix.PubSub` on `"kelixip:status"`. Unlike scenario
  monitoring, kelixip has no subscription for this data (`status/0` is a
  snapshot, not a stream) — kelescope polls it on a timer instead.
  """
  use GenServer
  require Logger

  @status_topic "kelixip:status"
  @poll_interval 20_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Last status successfully polled, or `nil` before the first poll completes."
  @spec snapshot(GenServer.server()) :: map() | nil
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
       topic: Keyword.get(opts, :status_topic, @status_topic),
       status: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:poll, state) do
    new_state =
      case Kelescope.Kelixip.Control.status(state.node) do
        {:ok, status} ->
          Phoenix.PubSub.broadcast(Kelescope.PubSub, state.topic, {:kelixip_status, status})
          %{state | status: status}

        {:error, reason} ->
          Logger.warning("kelixip status poll to #{state.node}: #{inspect(reason)}")
          state
      end

    Process.send_after(self(), :poll, state.interval)
    {:noreply, new_state}
  end
end
