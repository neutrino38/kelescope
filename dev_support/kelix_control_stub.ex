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
    GenServer.start_link(__MODULE__, %{subs: MapSet.new(), rows: @fake_rows}, name: __MODULE__)
  end

  def subscribe_monitor(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Pushes `msg` to every subscriber right away, bypassing the random tick (used by tests)."
  def push(msg), do: GenServer.cast(__MODULE__, {:push, msg})

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
  def handle_cast({:push, msg}, state) do
    for pid <- state.subs, do: send(pid, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    row = state.rows |> Enum.random() |> Map.put(:event, Enum.random(~w(ACK BYE INFO REGISTER)))

    for pid <- state.subs, do: send(pid, {:kelix_monitor, {:upsert, row}})

    {:noreply, state}
  end
end
