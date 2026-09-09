defmodule KelescopeWeb.ScenarioMonitorLive do
  use KelescopeWeb, {:live_view, KelescopeWeb.Monitor.Gettext}

  @columns ~w(id domain function script account state event command medias mediaserver outbound)a

  alias Kelescope.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:scenarios")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:link")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:status")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, Kelescope.Kelixip.AuthDbPoller.topic())
    end

    # PubSub doesn't replay: fetch what Link already knows so a mount after
    # the initial connect isn't stuck showing "connecting" until the next push.
    {status, rows} = Kelescope.Kelixip.Link.snapshot()

    {:ok,
     assign(socket,
       scenarios: visible(rows, socket.assigns.current_scope),
       link_status: status,
       columns: @columns,
       domain_filter: nil,
       kelixip_status: Kelescope.Kelixip.StatusPoller.snapshot(),
       auth_db: Kelescope.Kelixip.AuthDbPoller.snapshot(),
       expanded_status: false,
       expanded_auth_db: false,
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

  # One clause per panel rather than one that derives an assign name from the
  # event: the panel comes from the browser, and String.to_atom on it would let
  # any word reach the socket.
  def handle_event("toggle_panel", %{"panel" => "status"}, socket) do
    {:noreply, update(socket, :expanded_status, &(!&1))}
  end

  def handle_event("toggle_panel", %{"panel" => "auth-db"}, socket) do
    {:noreply, update(socket, :expanded_auth_db, &(!&1))}
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
    id = String.to_integer(id)

    if may_shut_down?(socket.assigns.scenarios, socket.assigns.current_scope, id),
      do: {:noreply, assign(socket, :pending_shutdown, id)},
      else: {:noreply, socket}
  end

  def handle_event("cancel_shutdown", _params, socket) do
    {:noreply, assign(socket, :pending_shutdown, nil)}
  end

  def handle_event("confirm_shutdown", %{"id" => id}, socket) do
    id = String.to_integer(id)
    scope = socket.assigns.current_scope

    # A hidden button is no protection: the event carries an identifier the
    # browser chose, so the domain is checked again here.
    if may_shut_down?(socket.assigns.scenarios, scope, id) do
      Kelescope.Kelixip.Control.shutdown_scenario(
        Kelescope.Kelixip.Link.target_node(),
        id,
        Scope.id(scope)
      )
    end

    {:noreply, assign(socket, :pending_shutdown, nil)}
  end

  @impl true
  def handle_info({:kelix_monitor, {:snapshot, rows}}, socket) do
    rows = visible(Map.new(rows, &{&1.id, &1}), socket.assigns.current_scope)
    {:noreply, assign(socket, :scenarios, rows)}
  end

  def handle_info({:kelix_monitor, {:upsert, row}}, socket) do
    if Scope.sees_domain?(socket.assigns.current_scope, Map.get(row, :domain)),
      do: {:noreply, update(socket, :scenarios, &Map.put(&1, row.id, row))},
      else: {:noreply, socket}
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

  def handle_info({:kelixip_auth_db, result}, socket) do
    {:noreply, assign(socket, :auth_db, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:monitor} locale={@locale} scope={@current_scope} />
    <Layouts.flash_group flash={@flash} />
    <div class="p-6">
      <div class={[
        "mb-4 rounded px-3 py-2 text-sm font-medium",
        @link_status == :connected && "bg-success/15 text-success",
        @link_status == :disconnected && "bg-error/15 text-error",
        @link_status == :connecting && "bg-warning/15 text-warning"
      ]}>
        kelixip: {@link_status}
      </div>

      <.status_panel
        :if={Scope.global?(@current_scope)}
        status={@kelixip_status}
        expanded={@expanded_status}
      />

      <.auth_db_panel
        result={@auth_db}
        detailed={Scope.global?(@current_scope)}
        expanded={@expanded_auth_db}
      />

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
                :if={Scope.can?(@current_scope, :shutdown, Map.get(row, :domain))}
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
        <strong>{Map.get(scenario(@scenarios, @pending_shutdown), :account, "-")}</strong>, {gettext(
          "domaine"
        )}
        <strong>{Map.get(scenario(@scenarios, @pending_shutdown), :domain, "-")}</strong>. {gettext(
          "Cette action interrompt le scénario en cours."
        )}
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

  attr :panel, :string, required: true
  attr :label, :string, required: true
  attr :expanded, :boolean, required: true

  defp panel_toggle(assigns) do
    ~H"""
    <button
      id={"#{@panel}-panel-toggle"}
      type="button"
      phx-click="toggle_panel"
      phx-value-panel={@panel}
      aria-expanded={to_string(@expanded)}
      class="flex items-center gap-2 text-left"
    >
      <span aria-hidden="true" class="text-base-content/40">
        {if @expanded, do: "▾", else: "▸"}
      </span>
      <span class="text-xs uppercase text-base-content/70">{@label}</span>
    </button>
    """
  end

  attr :status, :map, default: nil
  attr :expanded, :boolean, required: true

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
      <.panel_toggle panel="status" label={gettext("Statut kelixip")} expanded={@expanded} />

      <div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
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
      </div>

      <div :if={@expanded}>
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
    </div>
    """
  end

  @doc """
  State of the `auth_db` database connection, from that module's own control
  command. A global scope reads every field the module reports; any narrower
  scope reads only whether the connection holds, because the detail names the
  host, the port, the database and its user.
  """
  attr :result, :any, required: true
  attr :detailed, :boolean, required: true
  attr :expanded, :boolean, required: true

  def auth_db_panel(%{result: nil} = assigns) do
    ~H"""
    <div class="mb-4 rounded border border-dashed p-3 text-sm text-base-content/70">
      {gettext("Connexion BDD : en attente du premier relevé…")}
    </div>
    """
  end

  def auth_db_panel(%{result: {:error, :unknown_module}} = assigns) do
    ~H"""
    <div class="mb-4 rounded border border-dashed p-3 text-sm text-base-content/70">
      {gettext("Module auth_db absent de cette instance kelixip.")}
    </div>
    """
  end

  def auth_db_panel(%{result: {:error, _reason}} = assigns) do
    ~H"""
    <div class="mb-4 rounded border p-3 text-sm">
      <span class="text-xs uppercase text-base-content/70">{gettext("Connexion BDD")}</span>
      <span class="ml-2 rounded bg-warning/15 px-2 py-0.5 text-xs font-medium text-warning">
        {gettext("état illisible")}
      </span>
    </div>
    """
  end

  def auth_db_panel(assigns) do
    {:ok, details} = assigns.result
    assigns = assign(assigns, :details, details)

    ~H"""
    <div class="mb-4 rounded border p-3">
      <div class="flex items-center gap-2">
        <.panel_toggle
          :if={@detailed}
          panel="auth-db"
          label={gettext("Connexion BDD")}
          expanded={@expanded}
        />
        <span :if={!@detailed} class="text-xs uppercase text-base-content/70">
          {gettext("Connexion BDD")}
        </span>
        <span class={[
          "rounded px-2 py-0.5 text-xs font-medium",
          auth_db_up(@details) == true && "bg-success/15 text-success",
          auth_db_up(@details) == false && "bg-error/15 text-error",
          is_nil(auth_db_up(@details)) && "bg-warning/15 text-warning"
        ]}>
          {auth_db_label(@details)}
        </span>
      </div>

      <div
        :if={@detailed and @expanded}
        class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-sm sm:grid-cols-3"
      >
        <div :for={{key, value} <- auth_db_rows(@details)}>
          <span class="text-xs uppercase text-base-content/70">{key}</span>
          <span class="ml-1 font-medium">{value}</span>
        </div>
      </div>
    </div>
    """
  end

  # The reduced view rests on one key, `state`, the one `kelictl auth_db show`
  # prints first. Any other value than up or down reads as unknown rather than
  # as healthy: a connection page must not call an unread state fine.
  defp auth_db_up(%{state: state}) when state in [:up, "up"], do: true
  defp auth_db_up(%{state: state}) when state in [:down, "down"], do: false
  defp auth_db_up(_details), do: nil

  defp auth_db_label(details) do
    case auth_db_up(details) do
      true -> gettext("connectée")
      false -> gettext("déconnectée")
      nil -> gettext("état inconnu")
    end
  end

  defp auth_db_rows(details) do
    details
    |> Map.delete(:state)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, format_auth_db_value(value)} end)
  end

  defp format_auth_db_value(value) when is_binary(value), do: value
  defp format_auth_db_value(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp format_auth_db_value(value), do: inspect(value)

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

  defp other_module_status(status), do: Map.get(status, :module_status, %{})

  defp domains(scenarios),
    do: scenarios |> Map.values() |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()

  # Filtering happens before the assign, so a row outside the scope never
  # reaches the socket, let alone the DOM.
  defp visible(scenarios, scope) do
    Map.filter(scenarios, fn {_id, row} -> Scope.sees_domain?(scope, Map.get(row, :domain)) end)
  end

  defp may_shut_down?(scenarios, scope, id) do
    case Map.fetch(scenarios, id) do
      {:ok, row} -> Scope.can?(scope, :shutdown, Map.get(row, :domain))
      :error -> false
    end
  end

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
