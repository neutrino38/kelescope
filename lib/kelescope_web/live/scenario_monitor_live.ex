defmodule KelescopeWeb.ScenarioMonitorLive do
  use KelescopeWeb, :live_view

  @columns ~w(id domain function script account state event command medias mediaserver outbound)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:scenarios")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:link")
    end

    # PubSub doesn't replay: fetch what Link already knows so a mount after
    # the initial connect isn't stuck showing "connecting" until the next push.
    {status, rows} = Kelescope.Kelixip.Link.snapshot()

    {:ok, assign(socket, scenarios: rows, link_status: status, columns: @columns)}
  end

  @impl true
  def handle_info({:kelix_monitor, {:snapshot, rows}}, socket) do
    {:noreply, assign(socket, :scenarios, Map.new(rows, &{&1.id, &1}))}
  end

  def handle_info({:kelix_monitor, {:upsert, row}}, socket) do
    {:noreply, update(socket, :scenarios, &Map.put(&1, row.id, row))}
  end

  def handle_info({:kelix_monitor, {:remove, id}}, socket) do
    {:noreply, update(socket, :scenarios, &Map.delete(&1, id))}
  end

  def handle_info({:kelixip_link, status}, socket) do
    {:noreply, assign(socket, :link_status, status)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class={[
        "mb-4 rounded px-3 py-2 text-sm font-medium",
        @link_status == :connected && "bg-green-100 text-green-800",
        @link_status == :disconnected && "bg-red-100 text-red-800",
        @link_status == :connecting && "bg-yellow-100 text-yellow-800"
      ]}>
        kelixip: {@link_status}
      </div>

      <table class="w-full text-left text-sm">
        <thead>
          <tr>
            <th :for={col <- @columns} class="border-b p-2">{col}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{_id, row} <- Enum.sort_by(@scenarios, fn {id, _row} -> id end)}>
            <td :for={col <- @columns} class="border-b p-2">{Map.get(row, col)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
