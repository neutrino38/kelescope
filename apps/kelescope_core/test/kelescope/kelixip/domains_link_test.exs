defmodule Kelescope.Kelixip.DomainsLinkTest do
  # `Kelix.Control` is a single globally-named process (see dev_support);
  # tests take it over one at a time, so they can't run concurrently.
  use ExUnit.Case, async: false

  alias Kelescope.Kelixip.DomainsLink

  @domains_topic "kelixip_domains_link_test:domains"
  @link_topic "kelixip_domains_link_test:link"

  # Same rationale as Kelescope.Kelixip.LinkTest: target node() itself against
  # a Kelix.Control double, rather than standing up a second distributed node.
  @node node()

  setup do
    :ok = Supervisor.terminate_child(Kelescope.Supervisor, Kelix.Control)

    on_exit(fn ->
      Supervisor.restart_child(Kelescope.Supervisor, Kelix.Control)
    end)

    Phoenix.PubSub.subscribe(Kelescope.PubSub, @domains_topic)
    Phoenix.PubSub.subscribe(Kelescope.PubSub, @link_topic)

    :ok
  end

  defp start_control!(domains) do
    {:ok, pid} =
      GenServer.start_link(
        Kelix.Control,
        %{counter_subs: MapSet.new(), domains: domains},
        name: Kelix.Control
      )

    pid
  end

  defp start_link!(retry_after \\ 50) do
    start_supervised!(
      {DomainsLink,
       node: @node,
       name: :test_domains_link,
       domains_topic: @domains_topic,
       link_topic: @link_topic,
       retry_after: retry_after}
    )
  end

  defp domain(name), do: %{name: name, active_calls: 0, registrations: 0}

  test "subscribes on start and publishes the initial snapshot" do
    start_control!([domain("d1")])
    start_link!()

    assert_receive {:kelixip_domains_link, :connected}
    assert_receive {:kelix_domains, {:snapshot, [%{name: "d1"}]}}
    assert {:connected, [%{name: "d1"}]} = DomainsLink.snapshot(:test_domains_link)
  end

  test "republishes counter updates pushed by the remote side" do
    control = start_control!([domain("d1")])
    start_link!()

    assert_receive {:kelixip_domains_link, :connected}
    assert_receive {:kelix_domains, {:snapshot, _domains}}

    Kelix.Control.push_counter({:kelix_domain_counter, "d1", :active_calls, 3})
    assert_receive {:kelix_domain_counter, "d1", :active_calls, 3}

    assert {:connected, [%{name: "d1", active_calls: 3}]} =
             DomainsLink.snapshot(:test_domains_link)

    GenServer.stop(control)
  end

  test "loses then regains the connection when the monitored node goes down and comes back" do
    control = start_control!([domain("d1")])
    link = start_link!(200)

    assert_receive {:kelixip_domains_link, :connected}
    assert_receive {:kelix_domains, {:snapshot, _domains}}

    send(link, {:nodedown, @node})
    assert_receive {:kelixip_domains_link, :disconnected}

    GenServer.stop(control)
    start_control!([domain("d1"), domain("d2")])

    assert_receive {:kelixip_domains_link, :connected}, 500
    assert_receive {:kelix_domains, {:snapshot, domains}}, 500
    assert length(domains) == 2
  end
end
