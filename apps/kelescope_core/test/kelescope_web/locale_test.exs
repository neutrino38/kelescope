defmodule KelescopeWeb.LocaleTest do
  use KelescopeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KelescopeWeb.Locale

  describe "from_accept_language/1" do
    test "takes the served locale of highest quality" do
      assert Locale.from_accept_language("en-GB,en;q=0.9,fr;q=0.8") == "en"
      assert Locale.from_accept_language("fr-CH;q=0.7,en;q=0.9") == "en"
      assert Locale.from_accept_language("en;q=0.7,fr;q=0.9") == "fr"
    end

    test "skips a locale kelescope does not serve" do
      assert Locale.from_accept_language("de-DE,de;q=0.9,en;q=0.5") == "en"
    end

    test "never selects a tag the browser refuses" do
      assert Locale.from_accept_language("en;q=0") == "fr"
    end

    test "falls back to French on anything it cannot use" do
      assert Locale.from_accept_language(nil) == "fr"
      assert Locale.from_accept_language("") == "fr"
      assert Locale.from_accept_language("*") == "fr"
      assert Locale.from_accept_language("de,es") == "fr"
    end

    test "reads a malformed quality as no quality at all" do
      assert Locale.from_accept_language("en;q=bogus") == "en"
    end
  end

  test "a browser asking for English is served English, without a stored choice", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "en-GB,en;q=0.9,fr;q=0.8")

    {:ok, _view, html} = live(conn, ~p"/login")

    assert html =~ "This workstation is not enrolled"
  end

  test "a browser asking for French is served French", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "fr-FR,fr;q=0.9")

    {:ok, _view, html} = live(conn, ~p"/login")

    assert html =~ "Poste non enrôlé"
  end

  test "the detected locale is stored, so the LiveView mount finds it", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "en")
      |> get(~p"/login")

    assert get_session(conn, :locale) == "en"
    assert conn.assigns.locale == "en"
  end

  test "an explicit choice beats the browser preference", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "en")
      |> Plug.Test.init_test_session(locale: "fr")
      |> get(~p"/login")

    assert get_session(conn, :locale) == "fr"
    assert html_response(conn, 200) =~ "Poste non enrôlé"
  end

  test "the public pages carry the language switch, having no navigation bar", %{conn: conn} do
    {:ok, login, _html} = live(conn, ~p"/login")

    assert has_element?(login, ~s|a[href="/locale/en"]|)
    assert has_element?(login, ~s|a[href="/locale/fr"]|)

    {:ok, enroll, _html} = live(conn, ~p"/enroll")

    assert has_element?(enroll, ~s|a[href="/locale/en"]|)
    assert has_element?(enroll, ~s|a[href="/locale/fr"]|)
  end

  test "a refused workstation reads its refusal in English", %{conn: conn} do
    {:ok, _view, html} =
      conn
      |> with_certificate(stray_certificate())
      |> Plug.Test.init_test_session(locale: "en")
      |> live(~p"/login")

    assert html =~ "Access denied"

    assert html =~
             "Your SSL client certificate is not associated with any kelescope access."

    refute html =~ "Accès refusé"
  end

  test "the switch stores the chosen locale", %{conn: conn} do
    conn = get(conn, ~p"/locale/en")

    assert redirected_to(conn) == "/"
    assert get_session(conn, :locale) == "en"
  end
end
