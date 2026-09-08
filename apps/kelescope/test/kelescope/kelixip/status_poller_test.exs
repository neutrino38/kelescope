defmodule Kelescope.Kelixip.StatusPollerTest do
  # `Kelix.Control` is a single globally-named process (see dev_support);
  # tests take it over one at a time, so they can't run concurrently.
  use ExUnit.Case, async: false

  alias Kelescope.Kelixip.StatusPoller

  @status_topic "kelixip_status_poller_test:status"

  # Same rationale as Kelescope.Kelixip.LinkTest: target node() itself against
  # a Kelix.Control double, rather than standing up a second distributed node.
  @node node()

  setup do
    :ok = Supervisor.terminate_child(Kelescope.Supervisor, Kelix.Control)

    on_exit(fn ->
      Supervisor.restart_child(Kelescope.Supervisor, Kelix.Control)
    end)

    Phoenix.PubSub.subscribe(Kelescope.PubSub, @status_topic)

    :ok
  end

  defp start_control!(status) do
    {:ok, pid} =
      GenServer.start_link(
        Kelix.Control,
        %{subs: MapSet.new(), rows: [], status: status},
        name: Kelix.Control
      )

    pid
  end

  defp start_poller!(poll_interval \\ 50) do
    start_supervised!(
      {StatusPoller,
       node: @node,
       name: :test_status_poller,
       status_topic: @status_topic,
       poll_interval: poll_interval}
    )
  end

  test "polls the initial status right away and republishes it" do
    start_control!(%{node: @node, uptime_ms: 1_000, instances: %{active: 1}})
    start_poller!()

    assert_receive {:kelixip_status, %{uptime_ms: 1_000}}
    assert %{uptime_ms: 1_000} = StatusPoller.snapshot(:test_status_poller)
  end

  test "polls again on the next tick and picks up a changed status" do
    start_control!(%{node: @node, uptime_ms: 1_000, instances: %{active: 1}})
    start_poller!()

    assert_receive {:kelixip_status, %{uptime_ms: 1_000}}

    Kelix.Control.set_status(%{node: @node, uptime_ms: 2_000, instances: %{active: 5}})

    assert_receive {:kelixip_status, %{uptime_ms: 2_000}}, 500
    assert %{uptime_ms: 2_000} = StatusPoller.snapshot(:test_status_poller)
  end
end
