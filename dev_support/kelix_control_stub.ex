defmodule Kelix.Control do
  @moduledoc """
  Stand-in for kelixip's real `Kelix.Control.subscribe_monitor/1`, which
  doesn't exist there yet (see docs/conception/phase1-monitoring/SPEC.md).

  Only compiled for :dev and :test (mix.exs `elixirc_paths`). When
  `KELIXIP_NODE` is unset, `Kelescope.Kelixip.Link` targets `node()` itself,
  so `:rpc.call/4` resolves locally to this module instead of a real remote
  kelixip — letting the LiveView be built and tested before the elixip-side
  patch lands.
  """
  use GenServer

  @fake_status %{
    node: node(),
    uptime_ms: 3_661_000,
    instances: %{active: 2},
    listeners: [
      %{proto: :udp, addr: "0.0.0.0", port: 5060, up: true},
      %{proto: :tls, addr: "0.0.0.0", port: 5061, up: true}
    ],
    media_pool: [
      %{name: "ms1", enabled: true, healthy: true},
      %{name: "ms2", enabled: true, healthy: false}
    ],
    modules: [:registrar, :conferencing],
    module_status: %{conferencing: %{active_conferences: 1, participants: 3}},
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
    }
  ]

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
    }
  ]

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{subs: MapSet.new(), rows: @fake_rows, status: @fake_status, domains: @fake_domains},
      name: __MODULE__
    )
  end

  def subscribe_monitor(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def status(), do: GenServer.call(__MODULE__, :status)

  def domains(), do: GenServer.call(__MODULE__, :domains)

  def domain(name), do: GenServer.call(__MODULE__, {:domain, name})

  @doc "Reloads `names`; `fallback.exs` always fails, to exercise the error path."
  def reload_script(names, _notify? \\ false), do: GenServer.call(__MODULE__, {:reload_script, names})

  @doc "Pushes `msg` to every subscriber right away, bypassing the random tick (used by tests)."
  def push(msg), do: GenServer.cast(__MODULE__, {:push, msg})

  @doc "Replaces the status `status/0` returns next (used by tests)."
  def set_status(status), do: GenServer.cast(__MODULE__, {:set_status, status})

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
    down = String.downcase(name)

    result =
      Enum.find(state.domains, fn d ->
        String.downcase(d.name) == down or down in Enum.map(d.aliases, &String.downcase/1)
      end)

    reply = if result, do: {:ok, result}, else: {:error, :not_found}
    {:reply, reply, state}
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
  def handle_cast({:set_status, status}, state) do
    {:noreply, %{state | status: status}}
  end

  @impl true
  def handle_info(:tick, state) do
    row = state.rows |> Enum.random() |> Map.put(:event, Enum.random(~w(ACK BYE INFO REGISTER)))

    for pid <- state.subs, do: send(pid, {:kelix_monitor, {:upsert, row}})

    {:noreply, state}
  end
end
