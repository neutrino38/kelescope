defmodule KelescopeWeb.ScenarioMonitorLive do
  use KelescopeWeb, :live_view

  @columns ~w(id domain function script account state event command medias mediaserver outbound)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:scenarios")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:link")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:status")
    end

    # PubSub doesn't replay: fetch what Link already knows so a mount after
    # the initial connect isn't stuck showing "connecting" until the next push.
    {status, rows} = Kelescope.Kelixip.Link.snapshot()

    {:ok,
     assign(socket,
       scenarios: rows,
       link_status: status,
       columns: @columns,
       kelixip_status: Kelescope.Kelixip.StatusPoller.snapshot()
     )}
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

  def handle_info({:kelixip_status, status}, socket) do
    {:noreply, assign(socket, :kelixip_status, status)}
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

      <.status_panel status={@kelixip_status} />

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

  attr :status, :map, default: nil

  def status_panel(%{status: nil} = assigns) do
    ~H"""
    <div class="mb-4 rounded border border-dashed p-3 text-sm text-gray-500">
      kelixip status: en attente du premier relevé…
    </div>
    """
  end

  def status_panel(assigns) do
    ~H"""
    <div class="mb-4 rounded border p-3">
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div>
          <div class="text-xs uppercase text-gray-500">Nœud</div>
          <div class="text-sm font-medium">{@status.node}</div>
        </div>
        <div>
          <div class="text-xs uppercase text-gray-500">Uptime</div>
          <div class="text-sm font-medium">{format_uptime(@status.uptime_ms)}</div>
        </div>
        <div>
          <div class="text-xs uppercase text-gray-500">Appels actifs</div>
          <div class="text-sm font-medium">{Map.get(@status.instances, :active, 0)}</div>
        </div>
        <div>
          <div class="text-xs uppercase text-gray-500">Version domaines</div>
          <div class="text-sm font-medium">{@status.domains_version}</div>
        </div>
      </div>

      <div class="mt-3">
        <div class="text-xs uppercase text-gray-500">Écouteurs</div>
        <div class="mt-1 flex flex-wrap gap-1">
          <span
            :for={l <- @status.listeners}
            class={[
              "rounded px-2 py-0.5 text-xs font-medium",
              l.up && "bg-green-100 text-green-800",
              !l.up && "bg-red-100 text-red-800"
            ]}
          >
            {l.proto}:{l.addr}:{l.port}
          </span>
          <span :if={@status.listeners == []} class="text-xs text-gray-500">(aucun)</span>
        </div>
      </div>

      <div class="mt-3">
        <div class="text-xs uppercase text-gray-500">Pool médias</div>
        <div class="mt-1 flex flex-wrap gap-1">
          <span
            :for={m <- @status.media_pool}
            class={[
              "rounded px-2 py-0.5 text-xs font-medium",
              m.enabled && m.healthy && "bg-green-100 text-green-800",
              m.enabled && !m.healthy && "bg-red-100 text-red-800",
              !m.enabled && "bg-gray-100 text-gray-600"
            ]}
          >
            {m.name}: {if m.enabled, do: "on", else: "off"}/{if m.healthy, do: "up", else: "down"}
          </span>
          <span :if={@status.media_pool == []} class="text-xs text-gray-500">(vide)</span>
        </div>
      </div>

      <div :if={map_size(Map.get(@status, :module_status, %{})) > 0} class="mt-3">
        <div class="text-xs uppercase text-gray-500">Modules</div>
        <div class="mt-1 space-y-0.5 text-sm">
          <div :for={{name, summary} <- Enum.sort_by(@status.module_status, &elem(&1, 0))}>
            <span class="font-medium">{name}</span>: {format_module_summary(summary)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_uptime(ms) do
    s = div(ms, 1000)
    "#{div(s, 3600)}h#{rem(div(s, 60), 60)}m#{rem(s, 60)}s"
  end

  defp format_module_summary(summary) when is_map(summary) do
    Enum.map_join(summary, ", ", fn {k, v} -> "#{k} #{v}" end)
  end

  defp format_module_summary(other), do: inspect(other)
end
