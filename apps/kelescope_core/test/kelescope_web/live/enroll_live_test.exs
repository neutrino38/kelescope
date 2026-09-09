defmodule KelescopeWeb.EnrollLiveTest do
  use KelescopeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey
  alias Kelescope.WebAuthnAuthenticator, as: Authenticator

  setup do
    id = "admin-#{System.unique_integer([:positive])}"
    {:ok, {_account, code}} = Auth.create_account(%{id: id, level: :admin, scope: :all})

    %{id: id, code: code, authenticator: Authenticator.new()}
  end

  test "the page is reachable without any certificate", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/enroll")

    assert html =~ "Enrôlement d&#39;un poste"
    assert html =~ "Code d&#39;invitation"
  end

  test "a wrong code goes nowhere", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/enroll")

    html = render_submit(view, "redeem", %{"admin_id" => id, "code" => "NOPE"})

    assert html =~ "Identifiant ou code invalide"
    assert html =~ "Code d&#39;invitation"
  end

  test "a full enrolment registers a passkey and issues a certificate", %{
    conn: conn,
    id: id,
    code: code,
    authenticator: authenticator
  } do
    {:ok, view, _html} = live(conn, ~p"/enroll")

    html = render_submit(view, "redeem", %{"admin_id" => id, "code" => code})
    assert html =~ "Libellé de la passkey"

    render_submit(view, "register_passkey", %{"label" => "clé jaune"})
    assert_push_event(view, "passkey:create", options)

    response = Authenticator.register(authenticator, challenge(options["challenge"]))
    html = render_hook(view, "passkey:result", response)
    assert html =~ "Libellé du poste"

    html = render_submit(view, "issue_certificate", %{"label" => "poste bureau"})
    assert_push_event(view, "download", download)

    assert download["filename"] == "kelescope-#{id}.p12"
    assert download["content_type"] == "application/x-pkcs12"
    assert byte_size(Base.decode64!(download["data"])) > 0
    assert html =~ "Certificat émis"
    assert html =~ "Fermez complètement le navigateur"

    {:ok, account} = Auth.fetch_account(id)
    assert [%{label: "clé jaune", credential_id: credential_id}] = account.passkeys
    assert credential_id == authenticator.credential_id
    assert [%{label: "poste bureau"}] = account.certificates
    assert account.invitation == nil
  end

  test "the code cannot be replayed after the enrolment", %{
    conn: conn,
    id: id,
    code: code,
    authenticator: authenticator
  } do
    enrol(conn, id, code, authenticator)

    {:ok, view, _html} = live(conn, ~p"/enroll")
    html = render_submit(view, "redeem", %{"admin_id" => id, "code" => code})

    assert html =~ "Identifiant ou code invalide"
  end

  test "the certificate issued lets the login page recognise the workstation", %{
    conn: conn,
    id: id,
    code: code,
    authenticator: authenticator
  } do
    enrol(conn, id, code, authenticator)

    {:ok, account} = Auth.fetch_account(id)
    [certificate] = account.certificates

    assert {:ok, %{id: ^id}, _certificate} =
             Auth.authenticate_certificate(certificate.fingerprint)
  end

  defp enrol(conn, id, code, authenticator) do
    {:ok, view, _html} = live(conn, ~p"/enroll")

    render_submit(view, "redeem", %{"admin_id" => id, "code" => code})
    render_submit(view, "register_passkey", %{"label" => "clé"})
    assert_push_event(view, "passkey:create", options)

    render_hook(
      view,
      "passkey:result",
      Authenticator.register(authenticator, challenge(options["challenge"]))
    )

    render_submit(view, "issue_certificate", %{"label" => "poste"})
    assert_push_event(view, "download", _download)

    view
  end

  defp challenge(bytes) do
    %{
      bytes: Base.url_decode64!(bytes, padding: false),
      origin: Passkey.origin(),
      rp_id: Passkey.rp_id()
    }
  end
end
