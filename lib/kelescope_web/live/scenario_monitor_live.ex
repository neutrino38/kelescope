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
       domain_filter: nil,
       kelixip_status: Kelescope.Kelixip.StatusPoller.snapshot(),
       selected_mediaserver: nil,
       pending_shutdown: nil
     )}
  end

  @impl true
  def handle_event("filter", %{"domain" => ""}, socket) do
    {:noreply, assign(socket, :domain_filter, nil)}
  end

  def handle_event("filter", %{"domain" => domain}, socket) do
    {:noreply, assign(socket, :domain_filter, domain)}
  end

  def handle_event("show_mediaserver", %{"name" => name}, socket) do
    media_pool =
      case socket.assigns.kelixip_status do
        nil -> []
        status -> Map.get(status, :media_pool, [])
      end

    {:noreply, assign(socket, :selected_mediaserver, Enum.find(media_pool, &(&1.name == name)))}
  end

  def handle_event("close_mediaserver", _params, socket) do
    {:noreply, assign(socket, :selected_mediaserver, nil)}
  end

  def handle_event("request_shutdown", %{"id" => id}, socket) do
    {:noreply, assign(socket, :pending_shutdown, String.to_integer(id))}
  end

  def handle_event("cancel_shutdown", _params, socket) do
    {:noreply, assign(socket, :pending_shutdown, nil)}
  end

  def handle_event("confirm_shutdown", %{"admin" => admin, "id" => id}, socket) do
    id = String.to_integer(id)
    Kelescope.Kelixip.Control.shutdown_scenario(Kelescope.Kelixip.Link.target_node(), id, admin)
    {:noreply, assign(socket, :pending_shutdown, nil)}
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
    <.nav current={:monitor} locale={@locale} />
    <div class="p-6">
      <div class={[
        "mb-4 rounded px-3 py-2 text-sm font-medium",
        @link_status == :connected && "bg-success/15 text-success",
        @link_status == :disconnected && "bg-error/15 text-error",
        @link_status == :connecting && "bg-warning/15 text-warning"
      ]}>
        kelixip: {@link_status}
      </div>

      <.status_panel status={@kelixip_status} />

      <form id="domain-filter-form" phx-change="filter" class="mb-3 flex items-center gap-2 text-sm">
        <label for="domain-filter">{gettext("Domaine")}</label>
        <select id="domain-filter" name="domain" class="select select-sm w-auto">
          <option value="">{gettext("Tous")}</option>
          <option
            :for={domain <- domains(@scenarios)}
            value={domain}
            selected={domain == @domain_filter}
          >
            {domain}
          </option>
        </select>
      </form>

      <table class="w-full text-left text-sm">
        <thead>
          <tr>
            <th :for={col <- @columns} class="border-b p-2">{col}</th>
            <th class="border-b p-2">{gettext("actions")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{_id, row} <- filtered_scenarios(@scenarios, @domain_filter)}>
            <td :for={col <- @columns} class="border-b p-2">{Map.get(row, col)}</td>
            <td class="border-b p-2">
              <button
                type="button"
                phx-click="request_shutdown"
                phx-value-id={row.id}
                class="btn btn-xs btn-error"
              >
                {gettext("Arrêter")}
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <.admin_confirm_modal
        :if={@pending_shutdown}
        id="shutdown-modal"
        title={gettext("Arrêter le scénario #%{id}", id: @pending_shutdown)}
        confirm_event="confirm_shutdown"
        cancel_event="cancel_shutdown"
        confirm_values={%{"id" => @pending_shutdown}}
        confirm_label={gettext("Arrêter")}
      >
        {gettext("Compte")}
        <strong>{Map.get(scenario(@scenarios, @pending_shutdown), :account, "-")}</strong>,
        {gettext("domaine")}
        <strong>{Map.get(scenario(@scenarios, @pending_shutdown), :domain, "-")}</strong>.
        {gettext("Cette action interrompt le scénario en cours.")}
      </.admin_confirm_modal>

      <.mediaserver_modal :if={@selected_mediaserver} mediaserver={@selected_mediaserver} />
    </div>
    """
  end

  attr :mediaserver, :map, required: true

  defp mediaserver_modal(assigns) do
    assigns =
      assign(assigns,
        addresses: mediaserver_addresses(assigns.mediaserver),
        server_status: mediaserver_server_status(assigns.mediaserver)
      )

    ~H"""
    <div
      id="mediaserver-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      phx-window-keydown="close_mediaserver"
      phx-key="escape"
    >
      <div
        class="max-h-[85vh] w-96 overflow-y-auto rounded bg-base-200 p-4 shadow-lg"
        phx-click-away="close_mediaserver"
      >
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-sm font-semibold uppercase text-base-content/70">
            {gettext("Médiaserveur")}
          </h2>
          <button
            type="button"
            phx-click="close_mediaserver"
            class="text-base-content/40 hover:text-base-content"
            aria-label={gettext("Fermer")}
          >
            ✕
          </button>
        </div>
        <dl class="space-y-2 text-sm">
          <div class="flex justify-between">
            <dt class="text-base-content/70">{gettext("Nom")}</dt>
            <dd class="font-medium">{@mediaserver.name}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/70">{gettext("Module")}</dt>
            <dd class="font-medium">{Map.get(@mediaserver, :module, "-")}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/70">{gettext("Adresse de contrôle")}</dt>
            <dd class="font-medium">{Map.get(@mediaserver, :url, "-")}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/70">{gettext("État")}</dt>
            <dd class="font-medium">
              {if @mediaserver.enabled, do: gettext("activé"), else: gettext("désactivé")}
            </dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/70">{gettext("Santé")}</dt>
            <dd class="font-medium">
              {if @mediaserver.healthy, do: gettext("opérationnel"), else: gettext("en défaut")}
            </dd>
          </div>
        </dl>

        <div class="mt-3">
          <div class="text-xs uppercase text-base-content/70">{gettext("Adresses réseau")}</div>
          <div :if={@addresses == []} class="mt-1 text-xs text-base-content/70">
            {gettext("non disponibles")}
          </div>
          <dl :if={@addresses != []} class="mt-1 space-y-0.5 text-sm">
            <div :for={{profile, addr, default?} <- @addresses} class="flex justify-between">
              <dt class="text-base-content/70">
                {profile}<span :if={default?}> ({gettext("défaut")})</span>
              </dt>
              <dd class="font-medium">{addr}</dd>
            </div>
          </dl>
        </div>

        <div :if={@server_status} class="mt-3">
          <div class="text-xs uppercase text-base-content/70">{gettext("Serveur")}</div>
          <dl class="mt-1 space-y-2 text-sm">
            <div class="flex justify-between">
              <dt class="text-base-content/70">{gettext("Version")}</dt>
              <dd class="font-medium">{get_in(@server_status, ["server", "version"]) || "-"}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/70">Uptime</dt>
              <dd class="font-medium">
                {format_uptime((get_in(@server_status, ["server", "uptimeSecs"]) || 0) * 1000)}
              </dd>
            </div>
            <div>
              <dt class="text-base-content/70">{gettext("Codecs audio")}</dt>
              <dd class="font-medium">
                {gettext("encodage")}: {string_list(@server_status, ~w(capabilities audio encode))}
              </dd>
              <dd class="font-medium">
                {gettext("décodage")}: {string_list(@server_status, ~w(capabilities audio decode))}
              </dd>
            </div>
            <div>
              <dt class="text-base-content/70">{gettext("Codecs vidéo")}</dt>
              <dd class="font-medium">
                {gettext("encodage")}: {string_list(@server_status, ~w(capabilities video encode))}
              </dd>
              <dd class="font-medium">
                {gettext("décodage")}: {string_list(@server_status, ~w(capabilities video decode))}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/70">{gettext("Sécurité")}</dt>
              <dd class="font-medium">
                {string_list(@server_status, ~w(security modes))}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/70">{gettext("Conférences en cours")}</dt>
              <dd class="font-medium">{get_in(@server_status, ["load", "conferences"]) || 0}</dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :map, default: nil

  def status_panel(%{status: nil} = assigns) do
    ~H"""
    <div class="mb-4 rounded border border-dashed p-3 text-sm text-base-content/70">
      {gettext("kelixip status: en attente du premier relevé…")}
    </div>
    """
  end

  def status_panel(assigns) do
    ~H"""
    <div class="mb-4 rounded border p-3">
      <div class={[
        "grid grid-cols-2 gap-3",
        if(auth_db_active?(@status), do: "sm:grid-cols-5", else: "sm:grid-cols-4")
      ]}>
        <div>
          <div class="text-xs uppercase text-base-content/70">{gettext("Nœud")}</div>
          <div class="text-sm font-medium">{@status.node}</div>
        </div>
        <div>
          <div class="text-xs uppercase text-base-content/70">Uptime</div>
          <div class="text-sm font-medium">{format_uptime(@status.uptime_ms)}</div>
        </div>
        <div>
          <div class="text-xs uppercase text-base-content/70">{gettext("Sessions actives")}</div>
          <div class="text-sm font-medium">{Map.get(@status.instances, :active, 0)}</div>
        </div>
        <div>
          <div class="text-xs uppercase text-base-content/70">{gettext("Version domaines")}</div>
          <div class="text-sm font-medium">{@status.domains_version}</div>
        </div>
        <div :if={auth_db_active?(@status)}>
          <div class="text-xs uppercase text-base-content/70">{gettext("Connexion BDD")}</div>
          <div class="text-sm font-medium">
            <span class={[
              "rounded px-2 py-0.5 text-xs font-medium",
              db_connected?(@status) && "bg-success/15 text-success",
              !db_connected?(@status) && "bg-error/15 text-error"
            ]}>
              {if db_connected?(@status), do: gettext("connectée"), else: gettext("déconnectée")}
            </span>
          </div>
        </div>
      </div>

      <div class="mt-3">
        <div class="text-xs uppercase text-base-content/70">{gettext("Écouteurs")}</div>
        <div class="mt-1 flex flex-wrap gap-1">
          <span
            :for={l <- @status.listeners}
            class={[
              "rounded px-2 py-0.5 text-xs font-medium",
              l.up && "bg-success/15 text-success",
              !l.up && "bg-error/15 text-error"
            ]}
          >
            {l.proto}:{l.addr}:{l.port}
          </span>
          <span :if={@status.listeners == []} class="text-xs text-base-content/70">
            {gettext("(aucun)")}
          </span>
        </div>
      </div>

      <div class="mt-3">
        <div class="text-xs uppercase text-base-content/70">{gettext("Pool médias")}</div>
        <div class="mt-1 flex flex-wrap gap-1">
          <button
            :for={m <- @status.media_pool}
            type="button"
            phx-click="show_mediaserver"
            phx-value-name={m.name}
            class={[
              "rounded px-2 py-0.5 text-xs font-medium",
              m.enabled && m.healthy && "bg-success/15 text-success",
              m.enabled && !m.healthy && "bg-error/15 text-error",
              !m.enabled && "bg-base-300 text-base-content/60"
            ]}
          >
            {m.name}: {if m.enabled, do: "on", else: "off"}/{if m.healthy, do: "up", else: "down"}
          </button>
          <span :if={@status.media_pool == []} class="text-xs text-base-content/70">
            {gettext("(vide)")}
          </span>
        </div>
      </div>

      <div :if={map_size(other_module_status(@status)) > 0} class="mt-3">
        <div class="text-xs uppercase text-base-content/70">{gettext("Modules")}</div>
        <div class="mt-1 space-y-0.5 text-sm">
          <div :for={{name, summary} <- Enum.sort_by(other_module_status(@status), &elem(&1, 0))}>
            <span class="font-medium">{name}</span>: {format_module_summary(summary)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp scenario(scenarios, id), do: Map.get(scenarios, id, %{})

  defp mediaserver_addresses(%{profiles: profiles}) when is_map(profiles) do
    profiles
    |> Enum.filter(fn {_profile, p} -> Map.get(p, :available) end)
    |> Enum.map(fn {profile, p} ->
      addr = presence(Map.get(p, :announced)) || presence(Map.get(p, :bind)) || "-"
      {profile, addr, Map.get(p, :default, false)}
    end)
    |> Enum.sort_by(fn {profile, _addr, _default} -> profile end)
  end

  defp mediaserver_addresses(_mediaserver), do: []

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp mediaserver_server_status(%{server_status: status}) when is_map(status), do: status
  defp mediaserver_server_status(_mediaserver), do: nil

  defp string_list(status, path) do
    case get_in(status, path) do
      list when is_list(list) and list != [] -> Enum.join(list, ", ")
      _other -> "-"
    end
  end

  defp auth_db_active?(status), do: :auth_db in Map.get(status, :modules, [])

  defp db_connected?(status) do
    status
    |> Map.get(:module_status, %{})
    |> Map.get(:auth_db, %{})
    |> Map.get(:connected, false)
  end

  defp other_module_status(status), do: Map.drop(Map.get(status, :module_status, %{}), [:auth_db])

  defp domains(scenarios),
    do: scenarios |> Map.values() |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()

  defp filtered_scenarios(scenarios, nil), do: Enum.sort_by(scenarios, fn {id, _row} -> id end)

  defp filtered_scenarios(scenarios, domain) do
    scenarios
    |> Enum.filter(fn {_id, row} -> row.domain == domain end)
    |> Enum.sort_by(fn {id, _row} -> id end)
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
