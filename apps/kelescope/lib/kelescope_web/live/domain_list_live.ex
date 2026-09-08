defmodule KelescopeWeb.DomainListLive do
  use KelescopeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:domains")
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:domains_link")
    end

    # PubSub doesn't replay: fetch what DomainsLink already knows so a mount
    # after the initial connect isn't stuck showing "connecting".
    {link_status, domains} = Kelescope.Kelixip.DomainsLink.snapshot()

    {:ok,
     assign(socket,
       domains: domains,
       link_status: link_status,
       expanded: nil,
       reload_result: nil,
       expanded_registrations: nil,
       registrations: nil,
       pending_removal: nil
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case Kelescope.Kelixip.Control.list_domains(Kelescope.Kelixip.Link.target_node()) do
      {:ok, domains} -> {:noreply, assign(socket, :domains, domains)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("toggle", %{"name" => name}, socket) do
    expanded = if socket.assigns.expanded == name, do: nil, else: name
    {:noreply, assign(socket, expanded: expanded, reload_result: nil)}
  end

  def handle_event("toggle_registrations", %{"name" => name}, socket) do
    if socket.assigns.expanded_registrations do
      Phoenix.PubSub.unsubscribe(
        Kelescope.PubSub,
        Kelescope.Kelixip.DomainsLink.registrations_topic(socket.assigns.expanded_registrations)
      )
    end

    if socket.assigns.expanded_registrations == name do
      {:noreply, assign(socket, expanded_registrations: nil, registrations: nil)}
    else
      Phoenix.PubSub.subscribe(
        Kelescope.PubSub,
        Kelescope.Kelixip.DomainsLink.registrations_topic(name)
      )

      registrations =
        case Kelescope.Kelixip.DomainsLink.registrations(name) do
          {:ok, regs} -> {:ok, regs}
          {:error, reason} -> {:error, reason}
        end

      {:noreply, assign(socket, expanded_registrations: name, registrations: registrations)}
    end
  end

  def handle_event(
        "request_remove_contact",
        %{"domain" => domain, "aor" => aor, "uri" => uri},
        socket
      ) do
    {:noreply, assign(socket, :pending_removal, %{domain: domain, aor: aor, uri: uri})}
  end

  def handle_event("cancel_remove_contact", _params, socket) do
    {:noreply, assign(socket, :pending_removal, nil)}
  end

  def handle_event(
        "confirm_remove_contact",
        %{"admin" => admin, "domain" => domain, "aor" => aor, "uri" => uri},
        socket
      ) do
    Kelescope.Kelixip.Control.unregister(
      Kelescope.Kelixip.Link.target_node(),
      domain,
      aor,
      uri,
      admin
    )

    {:noreply, assign(socket, :pending_removal, nil)}
  end

  def handle_event("reload", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.domains, &(&1.name == name)) do
      nil ->
        {:noreply, socket}

      domain ->
        reload_result =
          case Kelescope.Kelixip.Control.reload_scripts(
                 Kelescope.Kelixip.Link.target_node(),
                 script_names(domain)
               ) do
            {:ok, result} -> result
            {:error, reason} -> %{"—" => {:error, reason}}
          end

        domains =
          case Kelescope.Kelixip.Control.domain(Kelescope.Kelixip.Link.target_node(), name) do
            {:ok, refreshed} -> replace_domain(socket.assigns.domains, refreshed)
            {:error, _reason} -> socket.assigns.domains
          end

        {:noreply, assign(socket, domains: domains, reload_result: reload_result)}
    end
  end

  @impl true
  def handle_info({:kelix_domains, {:snapshot, domains}}, socket) do
    {:noreply, assign(socket, :domains, domains)}
  end

  def handle_info({:kelix_domain_counter, domain, kind, count}, socket) do
    domains =
      Enum.map(socket.assigns.domains, fn
        %{name: ^domain} = d -> Map.put(d, kind, count)
        d -> d
      end)

    {:noreply, assign(socket, :domains, domains)}
  end

  def handle_info({:kelixip_domains_link, status}, socket) do
    {:noreply, assign(socket, :link_status, status)}
  end

  def handle_info({:kelix_registrations, domain, {:upsert, reg}}, socket) do
    if socket.assigns.expanded_registrations == domain do
      {:noreply, update(socket, :registrations, &upsert_registration(&1, reg))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:kelix_registrations, domain, {:remove, aor}}, socket) do
    if socket.assigns.expanded_registrations == domain do
      {:noreply, update(socket, :registrations, &remove_registration(&1, aor))}
    else
      {:noreply, socket}
    end
  end

  defp replace_domain(domains, refreshed) do
    Enum.map(domains, fn
      %{name: name} when name == refreshed.name -> refreshed
      d -> d
    end)
  end

  defp upsert_registration({:ok, aors}, reg) do
    if Enum.any?(aors, &(&1.aor == reg.aor)) do
      {:ok, Enum.map(aors, &if(&1.aor == reg.aor, do: reg, else: &1))}
    else
      {:ok, aors ++ [reg]}
    end
  end

  defp upsert_registration(other, _reg), do: other

  defp remove_registration({:ok, aors}, aor), do: {:ok, Enum.reject(aors, &(&1.aor == aor))}
  defp remove_registration(other, _aor), do: other

  defp script_names(domain) do
    [domain.registrar, domain.presence | domain.dial_plan]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.get(&1, :script))
    |> Enum.uniq()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:domains} locale={@locale} />
    <div class="p-6">
      <div class={[
        "mb-4 rounded px-3 py-2 text-sm font-medium",
        @link_status == :connected && "bg-success/15 text-success",
        @link_status == :disconnected && "bg-error/15 text-error",
        @link_status == :connecting && "bg-warning/15 text-warning"
      ]}>
        kelixip: {@link_status}
      </div>

      <.header>
        {gettext("Domaines")}
        <:actions>
          <.button phx-click="refresh">{gettext("Rafraîchir")}</.button>
        </:actions>
      </.header>

      <div class="divide-y rounded border">
        <.domain_row
          :for={d <- @domains}
          domain={d}
          expanded={@expanded == d.name}
          expanded_registrations={@expanded_registrations == d.name}
          registrations={if @expanded_registrations == d.name, do: @registrations}
          reload_result={if @expanded == d.name, do: @reload_result}
        />
        <p :if={@domains == []} class="p-3 text-sm text-base-content/70">
          {gettext("Aucun domaine servi.")}
        </p>
      </div>

      <.admin_confirm_modal
        :if={@pending_removal}
        id="remove-contact-modal"
        title={gettext("Désenregistrer ce contact")}
        confirm_event="confirm_remove_contact"
        cancel_event="cancel_remove_contact"
        confirm_values={
          %{
            "domain" => @pending_removal.domain,
            "aor" => @pending_removal.aor,
            "uri" => @pending_removal.uri
          }
        }
        confirm_label={gettext("Désenregistrer")}
      >
        AOR <strong>{@pending_removal.aor}</strong>, {gettext("contact")} <strong>{@pending_removal.uri}</strong>.
      </.admin_confirm_modal>
    </div>
    """
  end

  attr :domain, :map, required: true
  attr :expanded, :boolean, required: true
  attr :expanded_registrations, :boolean, required: true
  attr :registrations, :any, default: nil
  attr :reload_result, :map, default: nil

  defp domain_row(assigns) do
    ~H"""
    <div class="p-3">
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-6 items-center">
        <button phx-click="toggle" phx-value-name={@domain.name} class="text-left link font-medium">
          {@domain.name}
        </button>
        <div class="text-sm">{Enum.join(@domain.aliases, ", ")}</div>
        <div class="text-sm">{Enum.join(@domain.functions, ", ")}</div>
        <div class="text-sm">{@domain.max_calls || "-"}</div>
        <div class="text-sm">{gettext("%{count} sessions actives", count: @domain.active_calls)}</div>
        <button
          phx-click="toggle_registrations"
          phx-value-name={@domain.name}
          class="text-left link text-sm"
        >
          {gettext("%{count} enregistrements", count: @domain.registrations)}
        </button>
      </div>

      <.domain_detail :if={@expanded} domain={@domain} reload_result={@reload_result} />
      <.registrations_detail
        :if={@expanded_registrations}
        registrations={@registrations}
        domain={@domain.name}
      />
    </div>
    """
  end

  attr :domain, :map, required: true
  attr :reload_result, :map, default: nil

  defp domain_detail(assigns) do
    ~H"""
    <div class="mt-3 border-t pt-3">
      <div class="mb-3">
        <div class="text-xs uppercase text-base-content/70 mb-1">Registrar</div>
        <.script_line cfg={@domain.registrar} />
      </div>

      <div class="mb-3">
        <div class="text-xs uppercase text-base-content/70 mb-1">Presence</div>
        <.script_line cfg={@domain.presence} />
      </div>

      <.table id={"dial-plan-#{@domain.name}"} rows={@domain.dial_plan}>
        <:col :let={rule} label={gettext("motif")}>
          {rule.pattern || (rule.default && gettext("défaut")) || "-"}
        </:col>
        <:col :let={rule} label="script">{rule.script}</:col>
        <:col :let={rule} label="module">{Map.get(rule, :module) || "-"}</:col>
        <:col :let={rule} label="version">{Map.get(rule, :version) || "-"}</:col>
        <:col :let={rule} label={gettext("état")}>
          {if Map.get(rule, :stale), do: gettext("obsolète"), else: gettext("à jour")}
        </:col>
      </.table>

      <div class="mt-3">
        <.button phx-click="reload" phx-value-name={@domain.name}>
          {gettext("Recharger les scénarios du domaine")}
        </.button>
      </div>

      <ul :if={@reload_result} class="mt-3 text-sm">
        <li :for={{script, result} <- @reload_result}>{script}: {reload_status(result)}</li>
      </ul>
    </div>
    """
  end

  attr :cfg, :map, default: nil

  defp script_line(%{cfg: nil} = assigns) do
    ~H"""
    <div class="text-sm text-base-content/70">{gettext("(non activé)")}</div>
    """
  end

  defp script_line(assigns) do
    ~H"""
    <div class="text-sm">
      {@cfg.script} — {Map.get(@cfg, :module) || gettext("non chargé")}
      <span :if={Map.get(@cfg, :version)}>(v{@cfg.version})</span>
      <span :if={Map.get(@cfg, :stale)} class="text-warning">{gettext("obsolète")}</span>
    </div>
    """
  end

  attr :registrations, :any, default: nil
  attr :domain, :string, default: nil

  defp registrations_detail(%{registrations: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="mt-3 border-t pt-3 text-sm text-error">
      {gettext("Impossible de lire les enregistrements : %{reason}", reason: inspect(@reason))}
    </p>
    """
  end

  defp registrations_detail(%{registrations: {:ok, aors}} = assigns) do
    assigns = assign(assigns, :aors, aors)

    ~H"""
    <div class="mt-3 border-t pt-3">
      <p :if={@aors == []} class="text-sm text-base-content/70">
        {gettext("Aucun enregistrement.")}
      </p>

      <div :for={entry <- @aors} class="mb-3">
        <div class="text-sm font-medium">{entry.aor}</div>

        <.table id={"registrations-#{entry.aor}"} rows={entry.contacts}>
          <:col :let={c} label="uri">{c.uri}</:col>
          <:col :let={c} label={gettext("expire dans (s)")}>{c.expires_in}</:col>
          <:col :let={c} label="source">{c.source || "-"}</:col>
          <:col :let={c} label="transport">{c.transport || "-"}</:col>
          <:col :let={c} label="instance">{c.instance || "-"}</:col>
          <:action :let={c}>
            <button
              type="button"
              phx-click="request_remove_contact"
              phx-value-domain={@domain}
              phx-value-aor={entry.aor}
              phx-value-uri={c.uri}
              class="btn btn-xs btn-error"
            >
              {gettext("Désenregistrer")}
            </button>
          </:action>
        </.table>
      </div>
    </div>
    """
  end

  defp reload_status(:ok), do: "ok"
  defp reload_status({:error, reason}), do: gettext("erreur : %{reason}", reason: inspect(reason))
end
