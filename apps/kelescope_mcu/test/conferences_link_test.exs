defmodule Kelescope.Kelixip.ConferencesLinkTest do
  # `Kelix.Control` is a single globally-named process (see dev_support);
  # tests take it over one at a time, so they can't run concurrently.
  use ExUnit.Case, async: false

  alias Kelescope.Kelixip.ConferencesLink

  @conferences_topic "kelixip_conferences_link_test:conferences"
  @link_topic "kelixip_conferences_link_test:link"

  # Same reasoning as LinkTest: no literal second Erlang node. Targeting
  # `node()` exercises the very `:rpc.call/4` path a remote node would, against
  # a `Kelix.Control` double this test owns.
  @node node()

  setup do
    :ok = Supervisor.terminate_child(Kelescope.Supervisor, Kelix.Control)
    on_exit(fn -> Kelescope.KelixStub.restore!() end)

    Phoenix.PubSub.subscribe(Kelescope.PubSub, @conferences_topic)
    Phoenix.PubSub.subscribe(Kelescope.PubSub, @link_topic)

    :ok
  end

  defp conf(uid, overrides \\ %{}) do
    Map.merge(
      %{
        uid: uid,
        name: uid,
        domain: "example.com",
        mcu: "ms1",
        layout: %{comp: 1, size: 6, auto: true},
        recording: nil,
        participants: [],
        medias: [:audio]
      },
      overrides
    )
  end

  defp start_control!(opts \\ []) do
    state = %{
      subs: MapSet.new(),
      rows: [],
      conferences: Keyword.get(opts, :conferences, [conf("c-1")]),
      conference_subs: MapSet.new(),
      conference_detail_subs: %{},
      conference_stats_subs: %{},
      push_capability: Keyword.get(opts, :push_capability, true),
      module_loaded: Keyword.get(opts, :module_loaded, true),
      stats_interval_ms: Keyword.get(opts, :stats_interval_ms, 15_000)
    }

    # Unlinked: some tests kill it on purpose, and a link would take the test
    # process with it. Registered `on_exit` before the setup's `restore!`, so it
    # frees the name first.
    {:ok, pid} = GenServer.start(Kelix.Control, state, name: Kelix.Control)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp start_link!(opts \\ []) do
    start_supervised!(
      {ConferencesLink,
       [
         node: @node,
         name: :test_conferences_link,
         conferences_topic: @conferences_topic,
         link_topic: @link_topic,
         retry_after: 50,
         poll_interval: 50
       ] ++ opts},
      id: {ConferencesLink, System.unique_integer()}
    )
  end

  test "subscribes on start and publishes the initial snapshot" do
    start_control!()
    start_link!()

    assert_receive {:kelixip_conferences_link, :push}
    assert_receive {:kelix_conferences, {:snapshot, [%{uid: "c-1"}]}}
    assert {:connected, :push, [%{uid: "c-1"}]} = ConferencesLink.snapshot(:test_conferences_link)
  end

  test "republishes an upsert and a removal, and tracks them in its own snapshot" do
    control = start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    send(link, {:kelix_conferences, {:upsert, conf("c-2")}})
    assert_receive {:kelix_conferences, {:upsert, %{uid: "c-2"}}}

    send(link, {:kelix_conferences, {:remove, "c-1"}})
    assert_receive {:kelix_conferences, {:remove, "c-1"}}

    assert {:connected, :push, [%{uid: "c-2"}]} = ConferencesLink.snapshot(link)
    assert Process.alive?(control)
  end

  test "applying the same upsert twice leaves one row" do
    start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    send(link, {:kelix_conferences, {:upsert, conf("c-1", %{name: "renamed"})}})
    send(link, {:kelix_conferences, {:upsert, conf("c-1", %{name: "renamed"})}})

    assert {:connected, :push, [%{uid: "c-1", name: "renamed"}]} = ConferencesLink.snapshot(link)
  end

  test "a removal naming an unknown conference changes nothing and does not crash" do
    start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    send(link, {:kelix_conferences, {:remove, "c-never-seen"}})
    assert_receive {:kelix_conferences, {:remove, "c-never-seen"}}

    assert {:connected, :push, [%{uid: "c-1"}]} = ConferencesLink.snapshot(link)
  end

  test "a node without the push contract falls back to polling the list" do
    start_control!(push_capability: false)
    link = start_link!()

    assert_receive {:kelixip_conferences_link, :poll}
    assert_receive {:kelix_conferences, {:snapshot, [%{uid: "c-1"}]}}
    assert {:connected, :poll, [%{uid: "c-1"}]} = ConferencesLink.snapshot(link)

    # No push to hold on to: the caller is told so, rather than shown an empty
    # panel.
    assert {:error, :unavailable} = ConferencesLink.watch_conference(link, "c-1")
    assert {:error, :unavailable} = ConferencesLink.watch_stats(link, "c-1")

    # and it keeps polling, which is what replaces the push there
    assert_receive {:kelix_conferences, {:snapshot, [%{uid: "c-1"}]}}, 500
  end

  test "a node upgraded in place is picked up, without restarting kelescope" do
    start_control!(push_capability: false)
    link = start_link!()

    assert_receive {:kelixip_conferences_link, :poll}

    # The mcu module gains the contract where it stands. Nothing restarts, and
    # nothing tells the link: the poll tick is what has to notice.
    :ok = Kelix.Control.set_push_capability(true)

    assert_receive {:kelixip_conferences_link, :push}, 1_000
    assert {:connected, :push, [%{uid: "c-1"}]} = ConferencesLink.snapshot(link)
    assert {:ok, _} = ConferencesLink.watch_conference(link, "c-1")
  end

  test "a node without the conferencing module gives an owner-less empty list, and is re-probed" do
    start_control!(module_loaded: false)
    link = start_link!()

    # `owner: nil` — nothing to watch, and no pid to monitor. Monitoring it
    # anyway would take the link down on the spot.
    assert_receive {:kelix_conferences, {:snapshot, []}}
    assert {:connected, :push, []} = ConferencesLink.snapshot(link)
    assert :sys.get_state(link).owner_ref == nil
    assert {:error, :not_found} = ConferencesLink.watch_conference(link, "c-1")

    # Nothing would ever wake the link up, so the poll timer has to.
    :ok = Kelix.Control.set_module_loaded(true)

    assert_receive {:kelix_conferences, {:snapshot, [%{uid: "c-1"}]}}, 1_000
    assert is_reference(:sys.get_state(link).owner_ref)
  end

  test "a hold survives one of two watchers dropping, and is released by the last" do
    start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    other = spawn_watcher(link, "c-1")

    assert {:ok, %{conference: %{uid: "c-1"}, participants: []}} =
             ConferencesLink.watch_conference(link, "c-1")

    assert held?(link, "c-1")

    :ok = ConferencesLink.unwatch_conference(link, "c-1")
    assert held?(link, "c-1"), "the other watcher still needs the subscription"

    stop_watcher(other)
    refute held?(link, "c-1")
  end

  test "a watcher that dies without unwatching releases its holds" do
    start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    watcher = spawn_watcher(link, "c-1")
    assert held?(link, "c-1")

    stop_watcher(watcher)
    refute held?(link, "c-1")
  end

  test "statistics disabled on the node are reported, never shown as an empty panel" do
    start_control!(stats_interval_ms: 0)
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    assert {:error, :disabled} = ConferencesLink.watch_stats(link, "c-1")
  end

  test "watching an unknown conference reports :not_found" do
    start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    assert {:error, :not_found} = ConferencesLink.watch_conference(link, "c-nope")
  end

  test "a statistics subscription pushes its first sample without being asked again" do
    start_control!(conferences: [conf("c-1", %{participants: [participant(7)]})])
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    Phoenix.PubSub.subscribe(Kelescope.PubSub, ConferencesLink.stats_topic("c-1"))
    assert {:ok, %{interval_ms: 15_000}} = ConferencesLink.watch_stats(link, "c-1")

    assert_receive {:kelix_conference_stats, "c-1", %{participants: [%{part_id: 7}]}}
  end

  test "the owner dying re-subscribes the list and every hold, and reloads their snapshots" do
    control = start_control!()
    link = start_link!()
    assert_receive {:kelix_conferences, {:snapshot, _}}

    Phoenix.PubSub.subscribe(Kelescope.PubSub, ConferencesLink.conference_topic("c-1"))
    assert {:ok, _} = ConferencesLink.watch_conference(link, "c-1")

    # The module was reloaded: the subscriber lists went with it, silently.
    # Nothing but the monitored owner tells kelescope its push is dead.
    Process.exit(control, :kill)
    wait_for_death(control)
    start_control!(conferences: [conf("c-1", %{name: "changed-while-blind"})])

    assert_receive {:kelix_conferences, {:snapshot, [%{name: "changed-while-blind"}]}}, 1_000

    assert_receive {:kelix_conference, "c-1",
                    {:snapshot, %{conference: %{name: "changed-while-blind"}}}},
                   1_000

    assert held?(link, "c-1")
  end

  defp participant(part_id) do
    %{
      part_id: part_id,
      name: "p#{part_id}",
      from: "sip:p#{part_id}@example.com",
      state: :connected,
      medias: [:audio],
      joined_at: ~U[2026-09-09 10:00:00Z]
    }
  end

  defp spawn_watcher(link, uid) do
    test = self()

    pid =
      spawn(fn ->
        ConferencesLink.watch_conference(link, uid)
        send(test, :watching)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :watching
    pid
  end

  defp stop_watcher(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    # The link learns of it through its own monitor, which lands after ours.
    :sys.get_state(:test_conferences_link)
    :ok
  end

  defp wait_for_death(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp held?(link, uid), do: Map.has_key?(:sys.get_state(link).holds, {:conference, uid})
end
