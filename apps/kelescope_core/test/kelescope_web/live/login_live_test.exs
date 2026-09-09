defmodule KelescopeWeb.LoginLiveTest do
  use KelescopeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey
  alias Kelescope.WebAuthnAuthenticator, as: Authenticator

  test "a browser without a certificate is told to enrol", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/login")

    assert html =~ "Poste non enrôlé"
    assert html =~ "/enroll"
  end

  test "an unknown certificate is refused without naming anyone", %{conn: conn} do
    {:ok, _view, html} = conn |> with_certificate(stray_certificate()) |> live(~p"/login")

    assert html =~ "Poste refusé"
  end

  test "a revoked certificate is refused", %{conn: conn} do
    admin = admin_fixture()
    {:ok, _} = Auth.issue_certificate(admin.id, "second poste")
    {:ok, _} = Auth.revoke_certificate(admin.id, admin.fingerprint)

    {:ok, _view, html} = conn |> with_certificate(admin) |> live(~p"/login")

    assert html =~ "Poste refusé"
    refute html =~ admin.id
  end

  test "an account without a passkey cannot open a session", %{conn: conn} do
    id = "admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_account(%{id: id, level: :admin, scope: :all})
    {:ok, issued} = Auth.issue_certificate(id, "poste sans passkey")

    {:ok, _view, html} = conn |> with_certificate(issued) |> live(~p"/login")

    assert html =~ "Aucune passkey enregistrée"
  end

  test "a full passkey ceremony opens the session", %{conn: conn} do
    admin = admin_fixture()
    conn = with_certificate(conn, admin)

    {:ok, view, html} = live(conn, ~p"/login")
    assert html =~ "Poste reconnu"

    render_click(view, "authenticate")
    assert_push_event(view, "passkey:get", options)

    response = Authenticator.authenticate(admin.authenticator, challenge(options), 42)
    html = render_hook(view, "passkey:result", response)

    assert html =~ "session-form"

    token = token_from(html)
    conn = post(bypass_csrf(conn), ~p"/session", %{"token" => token})

    assert redirected_to(conn) == "/"
    assert get_session(conn, "admin_id") == admin.id
    assert get_session(conn, "cert_fp") == admin.fingerprint

    {:ok, account} = Auth.fetch_account(admin.id)
    assert [%{sign_count: 42}] = account.passkeys
    assert account.last_login_at
  end

  test "a signature from another authenticator is refused", %{conn: conn} do
    admin = admin_fixture()
    {:ok, view, _html} = conn |> with_certificate(admin) |> live(~p"/login")

    render_click(view, "authenticate")
    assert_push_event(view, "passkey:get", options)

    intruder = %{Authenticator.new() | credential_id: admin.authenticator.credential_id}

    html =
      render_hook(
        view,
        "passkey:result",
        Authenticator.authenticate(intruder, challenge(options))
      )

    assert html =~ "La passkey n&#39;a pas été acceptée."
    refute html =~ "session-form"
  end

  test "a token cannot open a session from another workstation", %{conn: conn} do
    admin = admin_fixture()
    other = admin_fixture()

    token = KelescopeWeb.SessionController.sign_token(admin.id, admin.fingerprint)

    conn =
      conn |> with_certificate(other) |> bypass_csrf() |> post(~p"/session", %{"token" => token})

    assert redirected_to(conn) == "/login"
    assert get_session(conn, "admin_id") == nil
  end

  test "the logout button clears the session", %{conn: conn} do
    conn = conn |> log_in_admin() |> bypass_csrf() |> delete(~p"/session")

    assert redirected_to(conn) == "/login"
    assert get_session(conn, "admin_id") == nil
  end

  defp challenge(options) do
    %{
      bytes: Base.url_decode64!(options["challenge"], padding: false),
      origin: Passkey.origin(),
      rp_id: options["rpId"]
    }
  end

  defp token_from(html) do
    [_, token] = Regex.run(~r/name="token" value="([^"]+)"/, html)
    token
  end

  defp bypass_csrf(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, true)
end
