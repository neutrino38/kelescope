defmodule KelescopeWeb.AccountLiveTest do
  use KelescopeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey
  alias Kelescope.WebAuthnAuthenticator, as: Authenticator

  setup %{conn: conn} do
    admin = admin_fixture(:monitor, ["a.example.com"])
    %{conn: log_in(conn, admin), admin: admin}
  end

  test "lists my passkeys and my workstations", %{conn: conn, admin: admin} do
    {:ok, _view, html} = live(conn, ~p"/account")

    assert html =~ admin.id
    assert html =~ "clé de test"
    assert html =~ "poste de test"
    assert html =~ "poste courant"
  end

  test "adds a passkey", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/account")

    render_submit(view, "add_passkey", %{"label" => "clé jaune"})
    assert_push_event(view, "passkey:create", options)

    authenticator = Authenticator.new()
    response = Authenticator.register(authenticator, challenge(options["challenge"]))
    html = render_hook(view, "passkey:result", response)

    assert html =~ "clé jaune"

    {:ok, account} = Auth.fetch_account(admin.id)
    assert length(account.passkeys) == 2
  end

  test "issues a certificate for another workstation", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/account")

    html = render_submit(view, "add_certificate", %{"label" => "poste maison"})
    assert_push_event(view, "download", download)

    assert download["filename"] == "kelescope-#{admin.id}.p12"
    assert html =~ "poste maison"
    assert html =~ "Mot de passe du fichier"

    {:ok, account} = Auth.fetch_account(admin.id)
    assert length(account.certificates) == 2
  end

  test "refuses to revoke the last passkey", %{conn: conn, admin: admin} do
    {:ok, view, html} = live(conn, ~p"/account")

    refute html =~ "ask_revoke_passkey"

    [passkey] = admin.account.passkeys
    html = render_submit(view, "revoke_passkey", %{"credential" => encode(passkey.credential_id)})

    assert html =~ "C&#39;est votre dernière passkey."
  end

  test "revokes a passkey once another one exists", %{conn: conn, admin: admin} do
    {:ok, _} = Auth.add_passkey(admin.id, Authenticator.passkey(Authenticator.new(), "seconde"))
    {:ok, view, _html} = live(conn, ~p"/account")

    [passkey | _] = admin.account.passkeys
    html = render_submit(view, "revoke_passkey", %{"credential" => encode(passkey.credential_id)})

    assert html =~ "seconde"
    refute html =~ "clé de test"
  end

  test "refuses to revoke the workstation in use", %{conn: conn, admin: admin} do
    {:ok, _} = Auth.issue_certificate(admin.id, "poste maison")
    {:ok, view, html} = live(conn, ~p"/account")

    refute html =~ ~s(phx-value-fingerprint="#{admin.fingerprint}")

    html = render_submit(view, "revoke_certificate", %{"fingerprint" => admin.fingerprint})

    assert html =~ "Ce poste est celui que vous utilisez."
    assert {:ok, _, _} = Auth.authenticate_certificate(admin.fingerprint)
  end

  test "revokes another workstation", %{conn: conn, admin: admin} do
    {:ok, other} = Auth.issue_certificate(admin.id, "poste maison")
    {:ok, view, _html} = live(conn, ~p"/account")

    html = render_submit(view, "revoke_certificate", %{"fingerprint" => other.fingerprint})

    assert html =~ "révoqué"
    assert Auth.authenticate_certificate(other.fingerprint) == {:error, :revoked}
  end

  defp challenge(bytes) do
    %{
      bytes: Base.url_decode64!(bytes, padding: false),
      origin: Passkey.origin(),
      rp_id: Passkey.rp_id()
    }
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
end
