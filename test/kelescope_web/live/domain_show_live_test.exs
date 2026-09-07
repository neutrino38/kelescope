defmodule KelescopeWeb.DomainShowLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest

  test "shows a domain's configuration and dial-plan", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/domains/example.com")

    assert html =~ "Domaine example.com"
    assert html =~ "example.org"
    assert html =~ "registrar.exs"
    assert html =~ "Elixir.Registrar"
    assert html =~ "play.exs"
    assert html =~ "obsolète"
  end

  test "reloading the domain's scripts reports one result per script", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains/example.com")

    html = view |> element("button", "Recharger les scénarios du domaine") |> render_click()

    assert html =~ "registrar.exs: ok"
    assert html =~ "play.exs: ok"
    assert html =~ "fallback.exs: erreur"
  end

  test "an unknown domain shows an error instead of crashing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/domains/unknown.example")

    assert html =~ "Impossible de lire ce domaine"
  end
end
