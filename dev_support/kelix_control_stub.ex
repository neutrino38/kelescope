defmodule Kelix.Control do
  @moduledoc """
  Stand-in for kelixip's real `Kelix.Control` (see
  docs/conception/phase1-monitoring/SPEC.md) — including
  `subscribe_registrations/2`, `unregister/4` and `shutdown_scenario/2`, so
  kelescope can be built and tested without a live connection to a real
  kelixip node.

  Only compiled for :dev and :test (mix.exs `elixirc_paths`). When
  `KELIXIP_NODE` is unset, `Kelescope.Kelixip.Link` targets `node()` itself,
  so `:rpc.call/4` resolves locally to this module instead of a real remote
  kelixip — letting the LiveView be built and tested before the elixip-side
  patch lands.
  """
  use GenServer
  require Logger

  @fake_status %{
    node: node(),
    uptime_ms: 3_661_000,
    instances: %{active: 2},
    listeners: [
      %{proto: :udp, addr: "0.0.0.0", port: 5060, up: true},
      %{proto: :tls, addr: "0.0.0.0", port: 5061, up: true}
    ],
    media_pool: [
      %{
        name: "ms1",
        module: :mendooze,
        url: "https://10.0.0.5:8443",
        enabled: true,
        healthy: true,
        profiles: %{
          "publicv4" => %{available: true, announced: "203.0.113.9", bind: "10.0.0.5", default: true},
          "publicv6" => %{available: false, announced: "", bind: "", default: false},
          "internalv4" => %{available: true, announced: "", bind: "10.0.0.5", default: false},
          "internalv6" => %{available: false, announced: "", bind: "", default: false}
        },
        server_status: %{
          "server" => %{"version" => "1.14.0", "uptimeSecs" => 274_353},
          "capabilities" => %{
            "audio" => %{"encode" => ["opus", "pcma", "pcmu"], "decode" => ["opus", "pcma", "pcmu", "g722"]},
            "video" => %{"encode" => ["vp8", "h264"], "decode" => ["vp8", "h264"]}
          },
          "security" => %{"modes" => ["none", "sdes-srtp", "dtls-srtp"]},
          "load" => %{"conferences" => 1}
        }
      },
      %{
        name: "ms2",
        module: :mockup,
        url: "https://10.0.0.6:8443",
        enabled: true,
        healthy: false,
        profiles: :unknown,
        server_status: :unknown
      }
    ],
    modules: [:registrar, :conferencing, :auth_db],
    module_status: %{
      conferencing: %{active_conferences: 1, participants: 3},
      auth_db: %{connected: true}
    },
    domains_version: 3
  }

  @fake_domains [
    %{
      name: "example.com",
      aliases: ["example.org"],
      max_calls: 500,
      functions: [:registrar, :calls],
      registrar: %{script: "registrar.exs", module: "Elixir.Registrar", version: 3, stale: false},
      presence: nil,
      dial_plan: [
        %{
          pattern: "+339.*",
          default: false,
          script: "play.exs",
          module: "Elixir.Play",
          version: 2,
          stale: false
        },
        %{
          pattern: nil,
          default: true,
          script: "fallback.exs",
          module: "Elixir.Fallback",
          version: 1,
          stale: true
        }
      ],
      active_calls: 2,
      registrations: 5
    },
    %{
      name: "test.local",
      aliases: [],
      max_calls: nil,
      functions: [:calls],
      registrar: nil,
      presence: nil,
      dial_plan: [%{pattern: nil, default: true, script: "demo.exs"}],
      active_calls: 0,
      registrations: 0
    },
    %{
      name: "throwaway.local",
      aliases: [],
      max_calls: nil,
      functions: [:calls],
      registrar: nil,
      presence: nil,
      dial_plan: [%{pattern: nil, default: true, script: "demo.exs"}],
      active_calls: 0,
      registrations: 1
    }
  ]

  @fake_registrations %{
    "example.com" => [
      %{
        domain: "example.com",
        aor: "alice",
        contacts: [
          %{
            uri: "sip:alice@10.0.0.9:5060",
            expires_in: 1800,
            source: "udp 10.0.0.9:5060",
            transport: "udp",
            instance: "<urn:uuid:f81d4fae>",
            reg_id: "1",
            methods: nil
          },
          %{
            uri: "sip:alice@10.0.0.12:5061",
            expires_in: 300,
            source: "tls 10.0.0.12:5061",
            transport: "tls",
            instance: nil,
            reg_id: nil,
            methods: nil
          }
        ]
      },
      %{
        domain: "example.com",
        aor: "bob",
        contacts: [
          %{
            uri: "sip:bob@10.0.0.20:5060",
            expires_in: 3600,
            source: "udp 10.0.0.20:5060",
            transport: "udp",
            instance: nil,
            reg_id: nil,
            methods: nil
          }
        ]
      }
    ],
    "test.local" => [],
    "throwaway.local" => [
      %{
        domain: "throwaway.local",
        aor: "carol",
        contacts: [
          %{
            uri: "sip:carol@10.0.0.30:5060",
            expires_in: 1800,
            source: "udp 10.0.0.30:5060",
            transport: "udp",
            instance: nil,
            reg_id: nil,
            methods: nil
          }
        ]
      }
    ]
  }

  @fake_rows [
    %{
      id: 1,
      domain: "example.com",
      function: :calls,
      script: "play.exs",
      account: "+33970260233",
      state: "in_call",
      event: "ACK",
      command: "media_play",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    },
    %{
      id: 2,
      domain: "example.com",
      function: :registrar,
      script: "registrar.exs",
      account: "alice",
      state: "registered",
      event: "REGISTER",
      command: "reply 200",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    },
    %{
      id: 3,
      domain: "throwaway.local",
      function: :calls,
      script: "demo.exs",
      account: "throwaway",
      state: "ringing",
      event: "INVITE",
      command: "-",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    }
  ]

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{
        subs: MapSet.new(),
        counter_subs: MapSet.new(),
        registration_subs: %{},
        rows: @fake_rows,
        status: @fake_status,
        domains: @fake_domains,
        registrations: @fake_registrations
      },
      name: __MODULE__
    )
  end

  def subscribe_monitor(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def status(), do: GenServer.call(__MODULE__, :status)

  def domains(), do: GenServer.call(__MODULE__, :domains)

  def domain(name), do: GenServer.call(__MODULE__, {:domain, name})

  def subscribe_domain_counters(pid), do: GenServer.call(__MODULE__, {:subscribe_counters, pid})

  def subscribe_registrations(pid, domain),
    do: GenServer.call(__MODULE__, {:subscribe_registrations, pid, domain})

  @doc "Unregisters one contact from an AOR; logged and pushed to registration subscribers."
  def unregister(domain, aor, contact_uri, admin),
    do: GenServer.call(__MODULE__, {:unregister, domain, aor, contact_uri, admin})

  @doc "Shuts down a running scenario instance; logged and pushed to monitor subscribers."
  def shutdown_scenario(id, admin), do: GenServer.call(__MODULE__, {:shutdown_scenario, id, admin})

  @doc "Reloads `names`; `fallback.exs` always fails, to exercise the error path."
  def reload_script(names, _notify? \\ false),
    do: GenServer.call(__MODULE__, {:reload_script, names})

  @doc "Pushes `msg` to every scenario subscriber right away, bypassing the random tick (used by tests)."
  def push(msg), do: GenServer.cast(__MODULE__, {:push, msg})

  @doc "Pushes a `{:kelix_domain_counter, domain, kind, count}` to every counter subscriber (used by tests)."
  def push_counter(msg), do: GenServer.cast(__MODULE__, {:push_counter, msg})

  @doc "Replaces the status `status/0` returns next (used by tests)."
  def set_status(status), do: GenServer.cast(__MODULE__, {:set_status, status})

  @doc "Pushes a `{:kelix_registrations, domain, msg}` to that domain's subscribers (used by tests)."
  def push_registration(domain, msg), do: GenServer.cast(__MODULE__, {:push_registration, domain, msg})

  @impl true
  def init(state) do
    :timer.send_interval(3_000, :tick)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, state.rows, %{state | subs: MapSet.put(state.subs, pid)}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:domains, _from, state) do
    {:reply, state.domains, state}
  end

  @impl true
  def handle_call({:domain, name}, _from, state) do
    reply = if d = find_domain(state, name), do: {:ok, d}, else: {:error, :not_found}
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:subscribe_counters, pid}, _from, state) do
    {:reply, state.domains, %{state | counter_subs: MapSet.put(state.counter_subs, pid)}}
  end

  @impl true
  def handle_call({:subscribe_registrations, pid, name}, _from, state) do
    case find_domain(state, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      d ->
        regs = Map.get(state.registrations, d.name, [])
        subs = Map.update(state.registration_subs, d.name, MapSet.new([pid]), &MapSet.put(&1, pid))
        {:reply, {:ok, %{domain: d.name, registrations: regs}}, %{state | registration_subs: subs}}
    end
  end

  @impl true
  def handle_call({:unregister, name, aor, contact_uri, admin}, _from, state) do
    with d when not is_nil(d) <- find_domain(state, name),
         registration when not is_nil(registration) <-
           Enum.find(Map.get(state.registrations, d.name, []), &(&1.aor == aor)),
         true <- Enum.any?(registration.contacts, &(&1.uri == contact_uri)) do
      Logger.info(
        "registration contact removed by admin=#{admin} domain=#{d.name} aor=#{aor} uri=#{contact_uri}"
      )

      regs = Map.get(state.registrations, d.name, [])
      remaining = Enum.reject(registration.contacts, &(&1.uri == contact_uri))

      {updated_regs, push} =
        if remaining == [] do
          {Enum.reject(regs, &(&1.aor == aor)), {:remove, aor}}
        else
          updated = %{registration | contacts: remaining}
          {Enum.map(regs, &if(&1.aor == aor, do: updated, else: &1)), {:upsert, updated}}
        end

      for pid <- Map.get(state.registration_subs, d.name, MapSet.new()),
          do: send(pid, {:kelix_registrations, d.name, push})

      new_state = %{state | registrations: Map.put(state.registrations, d.name, updated_regs)}
      {:reply, :ok, new_state}
    else
      # matches the real `Kelix.Control.unregister/3,4` contract: a bare
      # `:notfound` atom, not an `{:error, _}` tuple.
      _ -> {:reply, :notfound, state}
    end
  end

  @impl true
  def handle_call({:shutdown_scenario, id, admin}, _from, state) do
    case Enum.find(state.rows, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      row ->
        Logger.info("scenario #{id} (#{row.account}@#{row.domain}) shut down by admin=#{admin}")

        for pid <- state.subs, do: send(pid, {:kelix_monitor, {:remove, id}})

        {:reply, :ok, %{state | rows: Enum.reject(state.rows, &(&1.id == id))}}
    end
  end

  @impl true
  def handle_call({:reload_script, names}, _from, state) do
    reply =
      Map.new(names, fn
        "fallback.exs" -> {"fallback.exs", {:error, :compile_error}}
        name -> {name, :ok}
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:push, msg}, state) do
    for pid <- state.subs, do: send(pid, msg)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:push_counter, msg}, state) do
    for pid <- state.counter_subs, do: send(pid, msg)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_status, status}, state) do
    {:noreply, %{state | status: status}}
  end

  @impl true
  def handle_cast({:push_registration, domain, msg}, state) do
    for pid <- Map.get(state.registration_subs, domain, MapSet.new()),
        do: send(pid, {:kelix_registrations, domain, msg})

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    row = state.rows |> Enum.random() |> Map.put(:event, Enum.random(~w(ACK BYE INFO REGISTER)))

    for pid <- state.subs, do: send(pid, {:kelix_monitor, {:upsert, row}})

    {:noreply, state}
  end

  defp find_domain(state, name) do
    down = String.downcase(name)

    Enum.find(state.domains, fn d ->
      String.downcase(d.name) == down or down in Enum.map(d.aliases, &String.downcase/1)
    end)
  end
end
