defmodule Kelescope.Kelixip.DomainsLink do
  @moduledoc """
  Owns a second connection to the monitored kelixip node (same node as
  `Kelescope.Kelixip.Link`, its own subscription) and republishes domain
  counter updates locally via `Phoenix.PubSub` (topic `"kelixip:domains"`);
  connection status goes out on `"kelixip:domains_link"`. Also keeps the last
  known snapshot so a LiveView mounting after the initial connect can fetch
  the current state instead of waiting for the next push (PubSub doesn't
  replay).

  Also subscribes to a domain's registrations on demand (see
  `registrations/2`), republished on `registrations_topic/1`.
  """
  use GenServer
  require Logger

  @domains_topic "kelixip:domains"
  @link_topic "kelixip:domains_link"
  @retry_after 5_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.server()) ::
          {:connected | :disconnected | :connecting, [map()]}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  Registrations for `domain` (AORs and their contacts). Subscribes this link
  to that domain's registration updates on first call — republished locally
  via `Phoenix.PubSub` on `"kelixip:registrations:" <> domain` (canonical
  name) as they change; callers subscribe to that topic themselves for live
  updates (PubSub doesn't replay, so this call's return value is the initial
  snapshot).
  """
  @spec registrations(GenServer.server(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def registrations(server \\ __MODULE__, domain),
    do: GenServer.call(server, {:registrations, domain})

  @spec registrations_topic(String.t()) :: String.t()
  def registrations_topic(domain), do: "kelixip:registrations:" <> domain

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
       domains: [],
       registrations: %{},
       registration_subs: MapSet.new(),
       domains_topic: Keyword.get(opts, :domains_topic, @domains_topic),
       link_topic: Keyword.get(opts, :link_topic, @link_topic),
       retry_after: Keyword.get(opts, :retry_after, @retry_after)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.status, state.domains}, state}
  end

  def handle_call({:registrations, domain}, _from, state) do
    if MapSet.member?(state.registration_subs, domain) do
      {:reply, {:ok, Map.get(state.registrations, domain, [])}, state}
    else
      case Kelescope.Kelixip.Control.subscribe_registrations(state.node, self(), domain) do
        {:ok, %{domain: canonical, registrations: regs}} ->
          new_state = %{
            state
            | registrations: Map.put(state.registrations, canonical, regs),
              registration_subs: MapSet.put(state.registration_subs, canonical)
          }

          {:reply, {:ok, regs}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_and_subscribe(state) do
      {:ok, domains} ->
        broadcast(state.link_topic, {:kelixip_domains_link, :connected})
        broadcast(state.domains_topic, {:kelix_domains, {:snapshot, domains}})
        {:noreply, %{state | status: :connected, domains: domains}}

      {:error, reason} ->
        Logger.warning(
          "kelixip domains link to #{state.node}: #{inspect(reason)}, retrying in #{state.retry_after}ms"
        )

        broadcast(state.link_topic, {:kelixip_domains_link, :disconnected})
        Process.send_after(self(), :connect, state.retry_after)
        {:noreply, %{state | status: :disconnected}}
    end
  end

  def handle_info({:kelix_domain_counter, domain, kind, count} = msg, state) do
    broadcast(state.domains_topic, msg)

    domains =
      Enum.map(state.domains, fn
        %{name: ^domain} = d -> Map.put(d, kind, count)
        d -> d
      end)

    {:noreply, %{state | domains: domains}}
  end

  def handle_info({:kelix_registrations, domain, {:upsert, reg}} = msg, state) do
    broadcast(registrations_topic(domain), msg)

    regs = Map.get(state.registrations, domain, [])

    updated =
      if Enum.any?(regs, &(&1.aor == reg.aor)) do
        Enum.map(regs, &if(&1.aor == reg.aor, do: reg, else: &1))
      else
        regs ++ [reg]
      end

    {:noreply, %{state | registrations: Map.put(state.registrations, domain, updated)}}
  end

  def handle_info({:kelix_registrations, domain, {:remove, aor}} = msg, state) do
    broadcast(registrations_topic(domain), msg)

    regs = state.registrations |> Map.get(domain, []) |> Enum.reject(&(&1.aor == aor))
    {:noreply, %{state | registrations: Map.put(state.registrations, domain, regs)}}
  end

  def handle_info({:nodedown, node}, %{node: node} = state) do
    broadcast(state.link_topic, {:kelixip_domains_link, :disconnected})
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
      Kelescope.Kelixip.Control.subscribe_domain_counters(node, self())
    else
      false -> {:error, :connect_failed}
    end
  end
end
