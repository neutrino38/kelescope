defmodule Kelescope.Kelixip.Link do
  @moduledoc """
  Owns the connection to the monitored kelixip node and republishes scenario
  updates locally via `Phoenix.PubSub` (topic `"kelixip:scenarios"`);
  connection status goes out on `"kelixip:link"`. Also keeps the last known
  snapshot so a LiveView mounting after the initial connect can fetch the
  current state instead of waiting for the next push (PubSub doesn't replay).
  """
  use GenServer
  require Logger

  @scenarios_topic "kelixip:scenarios"
  @link_topic "kelixip:link"
  @retry_after 5_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.server()) ::
          {:connected | :disconnected | :connecting, %{optional(term()) => map()}}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    cookie = Keyword.get(opts, :cookie)
    :net_kernel.monitor_nodes(true)
    send(self(), :connect)

    {:ok,
     %{
       node: node,
       cookie: cookie,
       status: :connecting,
       rows: %{},
       scenarios_topic: Keyword.get(opts, :scenarios_topic, @scenarios_topic),
       link_topic: Keyword.get(opts, :link_topic, @link_topic),
       retry_after: Keyword.get(opts, :retry_after, @retry_after)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.status, state.rows}, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_and_subscribe(state) do
      {:ok, rows} ->
        rows_by_id = Map.new(rows, &{&1.id, &1})
        broadcast(state.link_topic, {:kelixip_link, :connected})
        broadcast(state.scenarios_topic, {:kelix_monitor, {:snapshot, rows}})
        {:noreply, %{state | status: :connected, rows: rows_by_id}}

      {:error, reason} ->
        Logger.warning(
          "kelixip link to #{state.node}: #{inspect(reason)}, retrying in #{state.retry_after}ms"
        )

        broadcast(state.link_topic, {:kelixip_link, :disconnected})
        Process.send_after(self(), :connect, state.retry_after)
        {:noreply, %{state | status: :disconnected}}
    end
  end

  def handle_info({:kelix_monitor, {:upsert, row}} = msg, state) do
    broadcast(state.scenarios_topic, msg)
    {:noreply, %{state | rows: Map.put(state.rows, row.id, row)}}
  end

  def handle_info({:kelix_monitor, {:remove, id}} = msg, state) do
    broadcast(state.scenarios_topic, msg)
    {:noreply, %{state | rows: Map.delete(state.rows, id)}}
  end

  def handle_info({:nodedown, node}, %{node: node} = state) do
    broadcast(state.link_topic, {:kelixip_link, :disconnected})
    Process.send_after(self(), :connect, state.retry_after)
    {:noreply, %{state | status: :disconnected}}
  end

  def handle_info({:nodedown, _other}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  defp broadcast(topic, msg), do: Phoenix.PubSub.broadcast(Kelescope.PubSub, topic, msg)

  defp connect_and_subscribe(%{node: node, cookie: cookie}) do
    if cookie, do: Node.set_cookie(node, String.to_atom(cookie))

    # Connecting to ourselves isn't meaningful (used by the dev/test stub,
    # see dev_support/kelix_control_stub.ex).
    with true <- node == node() or Node.connect(node) do
      Kelescope.Kelixip.Control.subscribe_monitor(node, self())
    else
      false -> {:error, :connect_failed}
    end
  end
end
