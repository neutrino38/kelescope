defmodule KelescopeWeb.DomainListLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  test "lists the served domains with their live counters", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/domains")

    assert html =~ "kelixip: connected"
    assert html =~ "example.com"
    assert html =~ "test.local"
    assert html =~ "example.org"
    assert html =~ "registrar, calls"
    assert html =~ "5 enregistrements"
  end

  test "refresh re-fetches the domain list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")

    assert view |> element("button", "Rafraîchir") |> render_click() =~ "example.com"
  end

  test "expanding a domain shows its detail, collapsing another one open", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/domains")
    refute html =~ "registrar.exs"

    html = view |> element("button", "example.com") |> render_click()
    assert html =~ "registrar.exs"
    assert html =~ "play.exs"
    assert html =~ "obsolète"

    # opening test.local's detail closes example.com's
    html = view |> element("button", "test.local") |> render_click()
    assert html =~ "demo.exs"
    refute html =~ "registrar.exs"

    # clicking the same domain again collapses it
    html = view |> element("button", "test.local") |> render_click()
    refute html =~ "demo.exs"
  end

  test "reloading a domain's scripts reports one result per script", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")
    view |> element("button", "example.com") |> render_click()

    html = view |> element("button", "Recharger les scénarios du domaine") |> render_click()

    assert html =~ "registrar.exs: ok"
    assert html =~ "play.exs: ok"
    assert html =~ "fallback.exs: erreur"
  end

  test "clicking the registration count shows the AORs and their contacts, grouped", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/domains")
    refute html =~ "sip:alice@10.0.0.9:5060"

    html = view |> element("button", "5 enregistrements") |> render_click()

    assert html =~ "alice"
    assert html =~ "sip:alice@10.0.0.9:5060"
    assert html =~ "sip:alice@10.0.0.12:5061"
    assert html =~ "bob"
    assert html =~ "sip:bob@10.0.0.20:5060"

    html = view |> element("button", "5 enregistrements") |> render_click()
    refute html =~ "sip:alice@10.0.0.9:5060"
  end

  test "an empty domain's registrations say so instead of showing nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")

    html = view |> element("button", "0 enregistrements") |> render_click()
    assert html =~ "Aucun enregistrement"
  end

  test "a counter update pushed via PubSub is reflected without a manual refresh", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")

    send(view.pid, {:kelix_domain_counter, "example.com", :active_calls, 9})

    assert render(view) =~ "9 sessions actives"
  end

  test "a registration update pushed by kelixip is reflected without a manual refresh", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/domains")
    view |> element("button", "5 enregistrements") |> render_click()

    dave = %{
      domain: "example.com",
      aor: "dave",
      contacts: [
        %{
          uri: "sip:dave@10.0.0.40:5060",
          expires_in: 60,
          source: "udp 10.0.0.40:5060",
          transport: "udp",
          instance: nil,
          reg_id: nil,
          methods: nil
        }
      ]
    }

    send(view.pid, {:kelix_registrations, "example.com", {:upsert, dave}})

    assert render(view) =~ "sip:dave@10.0.0.40:5060"
  end

  test "removing a contact asks for confirmation and an admin name, and logs who did it", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/domains")
    html = view |> element("button", "1 enregistrements") |> render_click()
    assert html =~ "sip:carol@10.0.0.30:5060"
    refute html =~ "Désenregistrer ce contact"

    html =
      view |> element("button[phx-value-uri='sip:carol@10.0.0.30:5060']") |> render_click()

    assert html =~ "Désenregistrer ce contact"

    # kelixip logs at :info; test config lowers the level to :warning to
    # keep the suite quiet, so raise it back for the duration of this test.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log(fn ->
          html =
            view
            |> form("#remove-contact-modal-form", %{"admin" => "alice-admin"})
            |> render_submit()

          refute html =~ "Désenregistrer ce contact"
        end)
      after
        Logger.configure(level: previous_level)
      end

    assert log =~ "domain=throwaway.local aor=carol uri=sip:carol@10.0.0.30:5060"
    assert log =~ "admin=alice-admin"
  end

  test "a contact removed by kelixip disappears from the registrations list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")
    html = view |> element("button", "5 enregistrements") |> render_click()
    assert html =~ "sip:alice@10.0.0.9:5060"

    send(view.pid, {:kelix_registrations, "example.com", {:remove, "alice"}})

    refute render(view) =~ "sip:alice@10.0.0.9:5060"
  end
end
