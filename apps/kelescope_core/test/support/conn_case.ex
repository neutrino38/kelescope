defmodule KelescopeWeb.ConnCase do
  @moduledoc """
  Test case for anything that goes through a connection.

  Tests run with authentication on, so the existing pages prove their role
  filtering too. `log_in_admin/3` gives a connection both factors: a client
  certificate on the peer data, and a session bound to its fingerprint.
  """

  use ExUnit.CaseTemplate

  alias Kelescope.Auth
  alias Kelescope.Auth.CA
  alias Kelescope.WebAuthnAuthenticator, as: Authenticator

  using do
    quote do
      # The default endpoint for testing
      @endpoint KelescopeWeb.Endpoint

      use KelescopeWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import KelescopeWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates an administrator with a workstation, and opens its session.
  """
  def log_in_admin(conn, level \\ :admin, scope \\ :all) do
    log_in(conn, admin_fixture(level, scope))
  end

  @doc """
  Creates an enrolled administrator: one account, one passkey, one client
  certificate. The identifier is unique, so tests stay independent inside the
  shared store.
  """
  def admin_fixture(level \\ :admin, scope \\ :all) do
    id = "admin-#{System.unique_integer([:positive])}"

    {:ok, {_account, _code}} = Auth.create_account(%{id: id, level: level, scope: scope})

    authenticator = Authenticator.new()
    {:ok, _account} = Auth.add_passkey(id, Authenticator.passkey(authenticator))

    {:ok, issued} = Auth.issue_certificate(id, "poste de test")
    {:ok, account} = Auth.fetch_account(id)

    %{
      account: account,
      id: id,
      authenticator: authenticator,
      der: issued.der,
      fingerprint: issued.fingerprint
    }
  end

  @doc """
  Puts the certificate on the connection and opens the session it belongs to.
  """
  def log_in(conn, admin) do
    conn
    |> with_certificate(admin)
    |> Plug.Test.init_test_session(Auth.session_payload(admin.id, admin.fingerprint))
  end

  @doc """
  Puts a certificate on the connection without opening a session.

  `Phoenix.LiveViewTest` reuses the connection as the socket's connect info, so
  the same peer data serves the request and the live mount.
  """
  def with_certificate(conn, %{der: der}) do
    Plug.Test.put_peer_data(conn, %{address: {127, 0, 0, 1}, port: 443, ssl_cert: der})
  end

  @doc """
  A certificate signed by the authority but never registered.
  """
  def stray_certificate do
    key = X509.PrivateKey.new_ec(:secp256r1)
    certificate = X509.Certificate.self_signed(key, "/CN=intrus")
    der = X509.Certificate.to_der(certificate)

    %{der: der, fingerprint: CA.fingerprint(der)}
  end
end
