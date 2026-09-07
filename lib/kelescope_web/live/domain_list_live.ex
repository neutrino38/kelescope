defmodule KelescopeWeb.DomainListLive do
  use KelescopeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :domains, fetch_domains())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :domains, fetch_domains())}
  end

  defp fetch_domains do
    Kelescope.Kelixip.Control.list_domains(Kelescope.Kelixip.Link.target_node())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:domains} />
    <div class="p-6">
      <.header>
        Domaines
        <:actions>
          <.button phx-click="refresh">Rafraîchir</.button>
        </:actions>
      </.header>

      <p :if={match?({:error, _}, @domains)} class="text-error">
        Impossible de lire les domaines : {inspect(elem(@domains, 1))}
      </p>

      <.table :if={match?({:ok, _}, @domains)} id="domains" rows={elem(@domains, 1)}>
        <:col :let={d} label="nom">
          <.link navigate={~p"/domains/#{d.name}"} class="link">{d.name}</.link>
        </:col>
        <:col :let={d} label="alias">{Enum.join(d.aliases, ", ")}</:col>
        <:col :let={d} label="fonctions">{Enum.join(d.functions, ", ")}</:col>
        <:col :let={d} label="appels max">{d.max_calls || "-"}</:col>
        <:col :let={d} label="appels actifs">{d.active_calls}</:col>
        <:col :let={d} label="enregistrements">{d.registrations}</:col>
      </.table>
    </div>
    """
  end
end
