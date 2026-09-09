defmodule Kelescope.Kelixip.ConferencesLink do
  @moduledoc """
  Owns the conference subscriptions on the monitored kelixip node and
  republishes them locally via `Phoenix.PubSub`, the same way
  `Kelescope.Kelixip.Link` and `Kelescope.Kelixip.DomainsLink` do for scenarios
  and domain counters. Three topics, one per panel (elixip
  `docs/design/mcu-live-push.md`):

    * `"kelixip:conferences"` — the list, as `{:kelix_conferences, {:snapshot,
      rows}}`, `{:kelix_conferences, {:upsert, row}}` and
      `{:kelix_conferences, {:remove, uid}}`
    * `conference_topic/1` — one conference and its whole roster
    * `stats_topic/1` — that conference's media statistics

  The last two are subscribed on demand and reference-counted: a watcher takes
  a hold with `watch_conference/2`, drops it with `unwatch_conference/2`, and
  the node-side subscription lives exactly as long as one watcher holds it. A
  statistics sweep left running for a collapsed panel costs the media server an
  RPC per leg every 15 s — see docs/architecture/adr-005-lien-conferences-partage.md.

  A node that does not serve the push contract falls back to polling the list,
  which is all this link's predecessor ever did. `snapshot/1` reports the mode
  in force, so the UI keeps its refresh button exactly there.
  """
  use GenServer
  require Logger

  alias Kelescope.Kelixip.Control

  @conferences_topic "kelixip:conferences"
  @link_topic "kelixip:conferences_link"
  @retry_after 5_000
  @poll_interval 10_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Connection status, delivery mode and the last known conference list (`nil`
  before the first successful read).

  `:push` means the node pushes changes and the list needs no refreshing;
  `:poll` means it does not serve the contract and the list is at most one poll
  interval old.
  """
  @spec snapshot(GenServer.server()) ::
          {:connected | :disconnected | :connecting, :push | :poll | nil, [map()] | nil}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc """
  Takes a hold on one conference for the calling process, and returns its row
  and roster.

  The caller then receives `{:kelix_conference, uid, _}` on
  `conference_topic(uid)`, which it subscribes to itself (PubSub does not
  replay, so this reply is the initial snapshot). `{:error, :unavailable}` means
  the node has no push to offer.
  """
  @spec watch_conference(GenServer.server(), String.t()) ::
          {:ok, %{conference: map(), participants: [map()]}}
          | {:error, :not_found | :unavailable | term()}
  def watch_conference(server \\ __MODULE__, uid),
    do: GenServer.call(server, {:watch, :conference, uid, self()})

  @doc "Drops the calling process's hold taken by `watch_conference/2`."
  @spec unwatch_conference(GenServer.server(), String.t()) :: :ok
  def unwatch_conference(server \\ __MODULE__, uid),
    do: GenServer.call(server, {:unwatch, :conference, uid, self()})

  @doc """
  Takes a hold on one conference's media statistics for the calling process,
  and returns the sweep interval plus the last sample seen, if any.

  The first sample of a fresh subscription arrives as a push, not in this
  reply. `{:error, :disabled}` means the node sweeps no statistics at all.
  """
  @spec watch_stats(GenServer.server(), String.t()) ::
          {:ok, %{interval_ms: pos_integer(), sample: map() | nil}}
          | {:error, :not_found | :disabled | :unavailable | term()}
  def watch_stats(server \\ __MODULE__, uid),
    do: GenServer.call(server, {:watch, :stats, uid, self()})

  @doc "Drops the calling process's hold taken by `watch_stats/2`."
  @spec unwatch_stats(GenServer.server(), String.t()) :: :ok
  def unwatch_stats(server \\ __MODULE__, uid),
    do: GenServer.call(server, {:unwatch, :stats, uid, self()})

  @spec conferences_topic() :: String.t()
  def conferences_topic, do: @conferences_topic

  @doc """
  Topic carrying `{:kelixip_conferences_link, :push | :poll}` whenever the mode
  settles, so a view opened while the node was down learns it gained (or lost)
  the push without being reloaded.
  """
  @spec link_topic() :: String.t()
  def link_topic, do: @link_topic

  @spec conference_topic(String.t()) :: String.t()
  def conference_topic(uid), do: "kelixip:conference:" <> uid

  @spec stats_topic(String.t()) :: String.t()
  def stats_topic(uid), do: "kelixip:conference_stats:" <> uid

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
       mode: nil,
       owner_ref: nil,
       conferences: nil,
       details: %{},
       samples: %{},
       intervals: %{},
       holds: %{},
       watcher_refs: %{},
       conferences_topic: Keyword.get(opts, :conferences_topic, @conferences_topic),
       link_topic: Keyword.get(opts, :link_topic, @link_topic),
       retry_after: Keyword.get(opts, :retry_after, @retry_after),
       poll_interval: Keyword.get(opts, :poll_interval, @poll_interval)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.status, state.mode, state.conferences}, state}
  end

  def handle_call({:watch, _kind, _uid, _pid}, _from, %{mode: mode} = state) when mode != :push do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:watch, kind, uid, pid}, _from, state) do
    if MapSet.member?(holders(state, kind, uid), pid) do
      {:reply, held_reply(kind, uid, state), state}
    else
      case subscribe(kind, uid, state) do
        {:ok, state} ->
          state = state |> add_hold(kind, uid, pid) |> monitor_watcher(pid)
          {:reply, held_reply(kind, uid, state), state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:unwatch, kind, uid, pid}, _from, state) do
    {:reply, :ok, release(state, kind, uid, pid)}
  end

  @impl true
  def handle_info(:connect, state) do
    was = state.mode
    if state.cookie, do: Node.set_cookie(state.node, String.to_atom(state.cookie))

    # Connecting to ourselves isn't meaningful (used by the dev/test stub,
    # see dev_support/kelix_control_stub.ex).
    with true <- state.node == node() or Node.connect(state.node),
         {:ok, %{owner: owner, conferences: rows}} <-
           Control.subscribe_conferences(state.node, self()) do
      state =
        %{
          state
          | status: :connected,
            mode: :push,
            owner_ref: monitor_owner(owner),
            conferences: rows
        }
        |> resubscribe_holds()

      # `owner: nil` is the node saying it runs without the conferencing module:
      # the list is empty and correct, but there is no pid whose death would
      # ever wake this link up. Re-probe on the poll timer, so a module loaded
      # later is picked up without restarting kelescope.
      if is_nil(owner), do: Process.send_after(self(), :connect, state.poll_interval)

      announce(state, was, :push)
      broadcast(state, state.conferences_topic, {:kelix_conferences, {:snapshot, rows}})
      {:noreply, state}
    else
      {:error, reason} ->
        if push_unsupported?(reason), do: poll_once(state, was), else: retry(state, reason)

      _not_connected ->
        retry(state, :connect_failed)
    end
  end

  def handle_info({:kelix_conferences, {:upsert, row}} = msg, state) do
    broadcast(state, state.conferences_topic, msg)
    {:noreply, %{state | conferences: upsert_row(state.conferences, row)}}
  end

  def handle_info({:kelix_conferences, {:remove, uid}} = msg, state) do
    broadcast(state, state.conferences_topic, msg)
    rows = state.conferences && Enum.reject(state.conferences, &(&1.uid == uid))
    {:noreply, %{state | conferences: rows}}
  end

  def handle_info({:kelix_conference, uid, {:snapshot, detail}} = msg, state) do
    broadcast(state, conference_topic(uid), msg)
    {:noreply, %{state | details: Map.put(state.details, uid, detail)}}
  end

  def handle_info({:kelix_conference, uid, :destroyed} = msg, state) do
    broadcast(state, conference_topic(uid), msg)
    {:noreply, %{state | details: Map.delete(state.details, uid)}}
  end

  def handle_info({:kelix_conference_stats, uid, sample} = msg, state) do
    broadcast(state, stats_topic(uid), msg)
    {:noreply, %{state | samples: Map.put(state.samples, uid, sample)}}
  end

  # The subscription owner died: kelixip's module was reloaded or restarted and
  # every subscription went with it, silently. Reconnecting re-subscribes the
  # list and every hold, and re-reads their snapshots — the push cannot say what
  # changed during the gap.
  #
  # The delay is not politeness. When the mcu module is not loaded at all,
  # `Kelix.ModuleRegistry.facade` answers with `owner: self()`, which under
  # `:rpc.call` is the short-lived process serving the call: it is already dead
  # when we monitor it. Retrying on a timer bounds that to one call per
  # interval instead of a re-subscription loop.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_ref: ref} = state) do
    Logger.warning("kelixip conferences owner on #{state.node} went down: #{inspect(reason)}")
    Process.send_after(self(), :connect, state.retry_after)
    {:noreply, %{state | status: :disconnected, mode: nil, owner_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, release_all(state, pid)}
  end

  def handle_info({:nodedown, node}, %{node: node} = state) do
    Process.send_after(self(), :connect, state.retry_after)
    {:noreply, %{state | status: :disconnected, mode: nil, owner_ref: nil}}
  end

  def handle_info({:nodedown, _other}, state), do: {:noreply, state}
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  defp retry(state, reason) do
    Logger.warning(
      "kelixip conferences link to #{state.node}: #{inspect(reason)}, " <>
        "retrying in #{state.retry_after}ms"
    )

    Process.send_after(self(), :connect, state.retry_after)
    {:noreply, %{state | status: :disconnected, mode: nil}}
  end

  # The node has no push to give: read the list once and come back later. The
  # poll interval doubles as the re-probe interval — a kelixip upgraded in place
  # must not leave kelescope polling for ever, and the failed subscribe that
  # precedes each read is one `:undef` reply, not a sweep.
  defp poll_once(state, was) do
    if was != :poll do
      Logger.info(
        "kelixip node #{state.node} serves no conference push: polling the list every " <>
          "#{state.poll_interval}ms"
      )
    end

    state = %{state | status: :connected, mode: :poll}
    announce(state, was, :poll)

    state =
      case Control.list_conferences(state.node) do
        {:ok, rows} ->
          broadcast(state, state.conferences_topic, {:kelix_conferences, {:snapshot, rows}})
          %{state | conferences: rows}

        {:error, reason} ->
          Logger.warning("kelixip conferences poll to #{state.node}: #{inspect(reason)}")
          state
      end

    Process.send_after(self(), :connect, state.poll_interval)
    {:noreply, state}
  end

  # Only when it changes: a view that already knows the mode has nothing to
  # learn from every poll tick repeating it.
  defp announce(_state, same, same), do: :ok

  defp announce(state, _was, mode),
    do: broadcast(state, state.link_topic, {:kelixip_conferences_link, mode})

  defp monitor_owner(nil), do: nil
  defp monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)

  # `:rpc.call/4` on a function the remote node does not export. A kelixip older
  # than the mcu-live-push contract answers exactly this, and it is the one
  # failure that must not be retried as a connection problem.
  defp push_unsupported?({:EXIT, {:undef, _}}), do: true
  defp push_unsupported?(_reason), do: false

  defp subscribe(:conference, uid, state) do
    case Control.subscribe_conference(state.node, self(), uid) do
      {:ok, %{conference: conf, participants: parts}} ->
        detail = %{conference: conf, participants: parts}
        {:ok, %{state | details: Map.put(state.details, uid, detail)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp subscribe(:stats, uid, state) do
    case Control.subscribe_conference_stats(state.node, self(), uid) do
      {:ok, %{interval_ms: interval}} ->
        {:ok, %{state | intervals: Map.put(state.intervals, uid, interval)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unsubscribe(:conference, uid, state) do
    Control.unsubscribe_conference(state.node, self(), uid)
    %{state | details: Map.delete(state.details, uid)}
  end

  defp unsubscribe(:stats, uid, state) do
    Control.unsubscribe_conference_stats(state.node, self(), uid)

    %{
      state
      | samples: Map.delete(state.samples, uid),
        intervals: Map.delete(state.intervals, uid)
    }
  end

  # After a reconnection the node knows nothing of the holds this link still
  # owes its watchers. Re-subscribing here is what lets them keep their panels
  # open across a module reload without touching them.
  defp resubscribe_holds(state) do
    Enum.reduce(state.holds, state, fn {{kind, uid}, _pids}, acc ->
      case subscribe(kind, uid, acc) do
        {:ok, acc} ->
          broadcast_hold(acc, kind, uid)
          acc

        {:error, reason} ->
          Logger.warning(
            "kelixip conferences link: could not re-subscribe #{kind} #{uid}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp broadcast_hold(state, :conference, uid) do
    case Map.fetch(state.details, uid) do
      {:ok, detail} ->
        broadcast(state, conference_topic(uid), {:kelix_conference, uid, {:snapshot, detail}})

      :error ->
        :ok
    end
  end

  # A fresh statistics subscription is swept on the spot node-side, so its first
  # sample arrives as a push: there is nothing to replay here.
  defp broadcast_hold(_state, :stats, _uid), do: :ok

  defp held_reply(:conference, uid, state), do: {:ok, Map.fetch!(state.details, uid)}

  defp held_reply(:stats, uid, state) do
    {:ok, %{interval_ms: Map.fetch!(state.intervals, uid), sample: Map.get(state.samples, uid)}}
  end

  defp holders(state, kind, uid), do: Map.get(state.holds, {kind, uid}, MapSet.new())

  defp add_hold(state, kind, uid, pid) do
    holds = Map.update(state.holds, {kind, uid}, MapSet.new([pid]), &MapSet.put(&1, pid))
    %{state | holds: holds}
  end

  defp release(state, kind, uid, pid) do
    remaining = state |> holders(kind, uid) |> MapSet.delete(pid)

    state =
      if MapSet.size(remaining) == 0 do
        kind |> unsubscribe(uid, state) |> Map.update!(:holds, &Map.delete(&1, {kind, uid}))
      else
        %{state | holds: Map.put(state.holds, {kind, uid}, remaining)}
      end

    demonitor_unless_holding(state, pid)
  end

  defp release_all(state, pid) do
    state.holds
    |> Map.keys()
    |> Enum.reduce(state, fn {kind, uid}, acc -> release(acc, kind, uid, pid) end)
  end

  defp monitor_watcher(state, pid) do
    if Map.has_key?(state.watcher_refs, pid) do
      state
    else
      %{state | watcher_refs: Map.put(state.watcher_refs, pid, Process.monitor(pid))}
    end
  end

  defp demonitor_unless_holding(state, pid) do
    still_holding? = Enum.any?(state.holds, fn {_key, pids} -> MapSet.member?(pids, pid) end)

    case {still_holding?, Map.fetch(state.watcher_refs, pid)} do
      {false, {:ok, ref}} ->
        Process.demonitor(ref, [:flush])
        %{state | watcher_refs: Map.delete(state.watcher_refs, pid)}

      _ ->
        state
    end
  end

  # Keyed by uid, so applying the same upsert twice is a no-op — the contract
  # delivers at least once, never exactly once.
  defp upsert_row(nil, row), do: [row]

  defp upsert_row(rows, row) do
    if Enum.any?(rows, &(&1.uid == row.uid)),
      do: Enum.map(rows, &if(&1.uid == row.uid, do: row, else: &1)),
      else: rows ++ [row]
  end

  defp broadcast(_state, topic, msg),
    do: Phoenix.PubSub.broadcast(Kelescope.PubSub, topic, msg)
end
