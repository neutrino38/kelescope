defmodule Kelescope.Kelixip.ConferencesPollerTest do
  # `Kelix.Control` is a single globally-named process (see dev_support);
  # tests take it over one at a time, so they can't run concurrently.
  use ExUnit.Case, async: false

  alias Kelescope.Kelixip.ConferencesPoller

  @conferences_topic "kelixip_conferences_poller_test:conferences"

  # Same rationale as Kelescope.Kelixip.LinkTest: target node() itself against
  # a Kelix.Control double, rather than standing up a second distributed node.
  @node node()

  setup do
    :ok = Supervisor.terminate_child(Kelescope.Supervisor, Kelix.Control)

    on_exit(fn ->
      Kelescope.KelixStub.restore!()
    end)

    Phoenix.PubSub.subscribe(Kelescope.PubSub, @conferences_topic)

    :ok
  end

  defp start_control!(conferences) do
    {:ok, pid} =
      GenServer.start_link(
        Kelix.Control,
        %{subs: MapSet.new(), rows: [], conferences: conferences},
        name: Kelix.Control
      )

    pid
  end

  defp start_poller!(poll_interval \\ 50) do
    start_supervised!(
      {ConferencesPoller,
       node: @node,
       name: :test_conferences_poller,
       conferences_topic: @conferences_topic,
       poll_interval: poll_interval}
    )
  end

  @seed_conf %{uid: "c-1", name: "standup", participants: [], recording: nil}

  test "polls the initial conference list right away and republishes it" do
    start_control!([@seed_conf])
    start_poller!()

    assert_receive {:kelixip_conferences, [%{uid: "c-1", name: "standup"}]}
    assert [%{uid: "c-1"}] = ConferencesPoller.snapshot(:test_conferences_poller)
  end

  test "polls again on the next tick and picks up a changed list" do
    start_control!([@seed_conf])
    start_poller!()

    assert_receive {:kelixip_conferences, [%{uid: "c-1"}]}

    {:ok, _reply} =
      GenServer.call(
        Kelix.Control,
        {:module_command, "mcu", "conference.create",
         %{"domain" => "example.com", "name" => "board"}}
      )

    assert_receive {:kelixip_conferences, [%{uid: "c-1"}, %{name: "board"}]}, 500
  end
end
