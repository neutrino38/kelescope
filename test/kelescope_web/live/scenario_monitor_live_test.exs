defmodule KelescopeWeb.ScenarioMonitorLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  test "shows the link status and scenario rows pushed via PubSub", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render(view) =~ "kelixip: connected"
    assert render(view) =~ "example.com"
    assert render(view) =~ "alice"
    assert render(view) =~ "Sessions actives"
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

  test "clicking a mediaserver in the pool shows its detail, closing it hides it again", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "Médiaserveur"

    html = view |> element("button[phx-value-name='ms1']") |> render_click()
    assert html =~ "Médiaserveur"
    assert html =~ "opérationnel"
    assert html =~ "203.0.113.9"
    assert html =~ "opus"
    assert html =~ "dtls-srtp"

    html = view |> element("button[aria-label='Fermer']") |> render_click()
    refute html =~ "Médiaserveur"
  end

  test "shows a mediaserver whose profiles/server_status are not probed yet as unavailable", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> element("button[phx-value-name='ms2']") |> render_click()
    assert html =~ "Médiaserveur"
    assert html =~ "en défaut"
    assert html =~ "non disponibles"
  end

  test "shows a database connection tile only when the auth_db module is active", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Connexion BDD"
    assert html =~ "connectée"

    send(
      view.pid,
      {:kelixip_status,
       %{
         node: :test@host,
         uptime_ms: 0,
         instances: %{},
         listeners: [],
         media_pool: [],
         modules: [:auth_db],
         module_status: %{auth_db: %{connected: false}},
         domains_version: 1
       }}
    )

    assert render(view) =~ "déconnectée"

    send(
      view.pid,
      {:kelixip_status,
       %{
         node: :test@host,
         uptime_ms: 0,
         instances: %{},
         listeners: [],
         media_pool: [],
         modules: [],
         module_status: %{},
         domains_version: 1
       }}
    )

    refute render(view) =~ "Connexion BDD"
  end

  test "shutting down a scenario asks for confirmation and an admin name, and logs who did it",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "Arrêter le scénario"

    html = view |> element("button[phx-value-id='3']") |> render_click()
    assert html =~ "Arrêter le scénario #3"

    # kelixip logs at :info; test config lowers the level to :warning to
    # keep the suite quiet, so raise it back for the duration of this test.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log(fn ->
          html =
            view
            |> form("#shutdown-modal-form", %{"admin" => "alice-admin"})
            |> render_submit()

          refute html =~ "Arrêter le scénario #3"
        end)
      after
        Logger.configure(level: previous_level)
      end

    assert log =~ "scenario 3"
    assert log =~ "admin=alice-admin"
  end
end
