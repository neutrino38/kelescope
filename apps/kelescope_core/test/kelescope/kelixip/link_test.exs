defmodule Kelescope.Kelixip.LinkTest do
  # `Kelix.Control` is a single globally-named process (see dev_support);
  # tests take it over one at a time, so they can't run concurrently.
  use ExUnit.Case, async: false

  alias Kelescope.Kelixip.Link

  @scenarios_topic "kelixip_link_test:scenarios"
  @link_topic "kelixip_link_test:link"

  # No literal second Erlang node: that would require making the whole test
  # VM a distributed node (`Node.start/2`), which would also change what
  # `node()` resolves to for the app's own self-targeting Link (started
  # under KELIXIP_NODE unset, see config/runtime.exs) and break unrelated
  # tests depending on run order. Targeting `node()` here exercises the same
  # `:rpc.call/4` path Link uses for a real remote node, against a
  # `Kelix.Control` double we fully control instead of the app's random tick.
  @node node()

  setup do
    :ok = Supervisor.terminate_child(Kelescope.Supervisor, Kelix.Control)

    on_exit(fn ->
      Kelescope.KelixStub.restore!()
    end)

    Phoenix.PubSub.subscribe(Kelescope.PubSub, @scenarios_topic)
    Phoenix.PubSub.subscribe(Kelescope.PubSub, @link_topic)

    :ok
  end

  defp start_control!(rows) do
    {:ok, pid} =
      GenServer.start_link(Kelix.Control, %{subs: MapSet.new(), rows: rows}, name: Kelix.Control)

    pid
  end

  defp start_link!(retry_after \\ 50) do
    start_supervised!(
      {Link,
       node: @node,
       name: :test_link,
       scenarios_topic: @scenarios_topic,
       link_topic: @link_topic,
       retry_after: retry_after}
    )
  end

  defp row(id), do: %{id: id, domain: "d", function: :calls, script: "s.exs", account: "a"}

  test "subscribes on start and publishes the initial snapshot" do
    start_control!([row(1)])
    start_link!()

    assert_receive {:kelixip_link, :connected}
    assert_receive {:kelix_monitor, {:snapshot, [%{id: 1}]}}
    assert {:connected, %{1 => %{id: 1}}} = Link.snapshot(:test_link)
  end

  test "republishes updates pushed by the remote side" do
    control = start_control!([row(1)])
    start_link!()

    assert_receive {:kelixip_link, :connected}
    assert_receive {:kelix_monitor, {:snapshot, _rows}}

    Kelix.Control.push({:kelix_monitor, {:upsert, row(2)}})
    assert_receive {:kelix_monitor, {:upsert, %{id: 2}}}
    assert {:connected, rows} = Link.snapshot(:test_link)
    assert map_size(rows) == 2

    Kelix.Control.push({:kelix_monitor, {:remove, 1}})
    assert_receive {:kelix_monitor, {:remove, 1}}
    assert {:connected, %{2 => _}} = Link.snapshot(:test_link)

    GenServer.stop(control)
  end

  test "loses then regains the connection when the monitored node goes down and comes back" do
    control = start_control!([row(1)])
    link = start_link!(200)

    assert_receive {:kelixip_link, :connected}
    assert_receive {:kelix_monitor, {:snapshot, _rows}}

    send(link, {:nodedown, @node})
    assert_receive {:kelixip_link, :disconnected}

    # the remote side comes back with a different scenario list before the
    # next retry (retry_after: 200 above leaves room for this swap).
    GenServer.stop(control)
    start_control!([row(1), row(2)])

    assert_receive {:kelixip_link, :connected}, 500
    assert_receive {:kelix_monitor, {:snapshot, rows}}, 500
    assert length(rows) == 2
  end

  test "a nodedown for the monitored node is treated as a disconnection" do
    control = start_control!([row(1)])
    link = start_link!()

    assert_receive {:kelixip_link, :connected}
    assert_receive {:kelix_monitor, {:snapshot, _rows}}

    send(link, {:nodedown, @node})
    assert_receive {:kelixip_link, :disconnected}

    GenServer.stop(control)
  end
end
