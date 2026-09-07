defmodule KelescopeWeb.DomainListLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest

  test "lists the served domains with their live counters", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/domains")

    assert html =~ "example.com"
    assert html =~ "test.local"
    assert html =~ "example.org"
    assert html =~ "registrar, calls"

    assert render(view) =~ "example.com"
  end

  test "links to each domain's detail page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")

    assert view |> element("a", "example.com") |> render() =~ ~s(href="/domains/example.com")
  end

  test "refresh re-fetches the domain list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/domains")

    assert view |> element("button", "Rafraîchir") |> render_click() =~ "example.com"
  end
end
