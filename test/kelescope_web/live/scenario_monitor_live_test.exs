defmodule KelescopeWeb.ScenarioMonitorLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest

  test "shows the link status and scenario rows pushed via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render(view) =~ "kelixip: connected"
    assert render(view) =~ "example.com"
    assert render(view) =~ "alice"
    assert render(view) =~ "Appels actifs"
  end

  test "updates the status panel on receipt of a kelixip_status message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    send(
      view.pid,
      {:kelixip_status,
       %{
         node: :test@host,
         uptime_ms: 3_600_000,
         instances: %{active: 7},
         listeners: [],
         media_pool: [],
         modules: [],
         module_status: %{},
         domains_version: 9
       }}
    )

    html = render(view)
    assert html =~ "test@host"
    assert html =~ "1h0m0s"
    assert html =~ "7"
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
