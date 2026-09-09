defmodule Kelescope.Kelixip.AuthDbPollerTest do
  # `Kelix.Control` is a single globally-named process (see dev_support);
  # tests take it over one at a time, so they can't run concurrently.
  use ExUnit.Case, async: false

  alias Kelescope.Kelixip.AuthDbPoller

  @auth_db_topic "kelixip_auth_db_poller_test:auth_db"

  # Same rationale as Kelescope.Kelixip.StatusPollerTest: target node() itself
  # against a Kelix.Control double.
  @node node()

  setup do
    :ok = Supervisor.terminate_child(Kelescope.Supervisor, Kelix.Control)

    on_exit(fn -> Kelescope.KelixStub.restore!() end)

    Phoenix.PubSub.subscribe(Kelescope.PubSub, @auth_db_topic)

    :ok
  end

  defp start_control!(auth_db) do
    {:ok, pid} =
      GenServer.start_link(
        Kelix.Control,
        %{subs: MapSet.new(), rows: [], status: %{}, auth_db: auth_db},
        name: Kelix.Control
      )

    pid
  end

  defp start_poller! do
    start_supervised!(
      {AuthDbPoller,
       node: @node, name: :test_auth_db_poller, auth_db_topic: @auth_db_topic, poll_interval: 50}
    )
  end

  test "asks the module's own control command and republishes what it answers" do
    start_control!(%{state: :up, host: "db.example.org", port: 3306})
    start_poller!()

    assert_receive {:kelixip_auth_db, {:ok, %{state: :up, host: "db.example.org"}}}
    assert {:ok, %{state: :up}} = AuthDbPoller.snapshot(:test_auth_db_poller)
  end

  test "publishes the failure too, so a stale state cannot pass for the current one" do
    control = start_control!(%{state: :up})
    start_poller!()

    assert_receive {:kelixip_auth_db, {:ok, %{state: :up}}}

    GenServer.stop(control)

    assert_receive {:kelixip_auth_db, {:error, _reason}}, 500
    assert {:error, _reason} = AuthDbPoller.snapshot(:test_auth_db_poller)
  end
end
