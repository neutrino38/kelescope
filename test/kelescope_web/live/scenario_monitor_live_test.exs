defmodule KelescopeWeb.ScenarioMonitorLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest

  test "shows the link status and scenario rows pushed via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render(view) =~ "kelixip: connected"
    assert render(view) =~ "example.com"
    assert render(view) =~ "alice"
  end

  test "upserts and removes rows pushed on the scenarios topic", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    row = %{
      id: 42,
      domain: "test.local",
      function: :calls,
      script: "demo.exs",
      account: "bob",
      state: "ringing",
      event: "INVITE",
      command: "-",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    }

    send(view.pid, {:kelix_monitor, {:upsert, row}})
    assert render(view) =~ "test.local"

    send(view.pid, {:kelix_monitor, {:remove, 42}})
    refute render(view) =~ "test.local"
  end
end
