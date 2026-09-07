defmodule KelescopeWeb.DomainShowLive do
  use KelescopeWeb, :live_view

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {:ok, assign(socket, name: name, domain: fetch_domain(name), reload_result: nil)}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    case socket.assigns.domain do
      {:ok, domain} ->
        node = Kelescope.Kelixip.Link.target_node()

        reload_result =
          case Kelescope.Kelixip.Control.reload_scripts(node, script_names(domain)) do
            {:ok, result} -> result
            {:error, reason} -> %{"—" => {:error, reason}}
          end

        {:noreply,
         socket
         |> assign(:reload_result, reload_result)
         |> assign(:domain, fetch_domain(socket.assigns.name))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp fetch_domain(name),
    do: Kelescope.Kelixip.Control.domain(Kelescope.Kelixip.Link.target_node(), name)

  defp script_names(domain) do
    [domain.registrar, domain.presence | domain.dial_plan]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.get(&1, :script))
    |> Enum.uniq()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:domains} />
    <div class="p-6">
      <.header>
        Domaine {@name}
        <:actions>
          <.button navigate={~p"/domains"}>← Domaines</.button>
        </:actions>
      </.header>

      <p :if={match?({:error, _}, @domain)} class="text-error">
        Impossible de lire ce domaine : {inspect(elem(@domain, 1))}
      </p>

      <.domain_details
        :if={match?({:ok, _}, @domain)}
        domain={elem(@domain, 1)}
        reload_result={@reload_result}
      />
    </div>
    """
  end

  attr :domain, :map, required: true
  attr :reload_result, :map, default: nil

  defp domain_details(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3 sm:grid-cols-4 mb-4">
      <div>
        <div class="text-xs uppercase text-gray-500">Alias</div>
        <div class="text-sm font-medium">{Enum.join(@domain.aliases, ", ")}</div>
      </div>
      <div>
        <div class="text-xs uppercase text-gray-500">Appels max</div>
        <div class="text-sm font-medium">{@domain.max_calls || "-"}</div>
      </div>
      <div>
        <div class="text-xs uppercase text-gray-500">Appels actifs</div>
        <div class="text-sm font-medium">{@domain.active_calls}</div>
      </div>
      <div>
        <div class="text-xs uppercase text-gray-500">Enregistrements</div>
        <div class="text-sm font-medium">{@domain.registrations}</div>
      </div>
    </div>

    <div class="mb-4">
      <div class="text-xs uppercase text-gray-500 mb-1">Registrar</div>
      <.script_line cfg={@domain.registrar} />
    </div>

    <div class="mb-4">
      <div class="text-xs uppercase text-gray-500 mb-1">Presence</div>
      <.script_line cfg={@domain.presence} />
    </div>

    <.table id="dial-plan" rows={@domain.dial_plan}>
      <:col :let={rule} label="motif">{rule.pattern || (rule.default && "défaut") || "-"}</:col>
      <:col :let={rule} label="script">{rule.script}</:col>
      <:col :let={rule} label="module">{Map.get(rule, :module) || "-"}</:col>
      <:col :let={rule} label="version">{Map.get(rule, :version) || "-"}</:col>
      <:col :let={rule} label="état">
        {if Map.get(rule, :stale), do: "obsolète", else: "à jour"}
      </:col>
    </.table>

    <div class="mt-4">
      <.button phx-click="reload">Recharger les scénarios du domaine</.button>
    </div>

    <ul :if={@reload_result} class="mt-3 text-sm">
      <li :for={{script, result} <- @reload_result}>{script}: {reload_status(result)}</li>
    </ul>
    """
  end

  attr :cfg, :map, default: nil

  defp script_line(%{cfg: nil} = assigns) do
    ~H"""
    <div class="text-sm text-gray-500">(non activé)</div>
    """
  end

  defp script_line(assigns) do
    ~H"""
    <div class="text-sm">
      {@cfg.script} — {Map.get(@cfg, :module) || "non chargé"}
      <span :if={Map.get(@cfg, :version)}>(v{@cfg.version})</span>
      <span :if={Map.get(@cfg, :stale)} class="text-warning">obsolète</span>
    </div>
    """
  end

  defp reload_status(:ok), do: "ok"
  defp reload_status({:error, reason}), do: "erreur : #{inspect(reason)}"
end
