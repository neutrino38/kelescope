defmodule KelescopeWeb.Plugs.AuthTest do
  use KelescopeWeb.ConnCase, async: true

  alias Kelescope.Auth
  alias KelescopeWeb.Plugs.Auth, as: AuthPlug

  describe "without both factors" do
    test "no certificate at all sends to the login page" do
      conn = visit("/")

      assert redirected_to(conn) == "/login"
      assert get_session(conn, "return_to") == "/"
      assert conn.halted
    end

    test "an unknown certificate sends to the login page" do
      conn = "/" |> visit(certificate: stray_certificate())

      assert redirected_to(conn) == "/login"
    end

    test "a certificate without a session sends to the login page" do
      conn = "/" |> visit(certificate: admin_fixture())

      assert redirected_to(conn) == "/login"
    end

    test "a session without its certificate is refused" do
      admin = admin_fixture()
      conn = visit("/", session: Auth.session_payload(admin.id, admin.fingerprint))

      assert redirected_to(conn) == "/login"
    end

    test "a session opened on another workstation is refused" do
      admin = admin_fixture()

      conn =
        visit("/",
          certificate: admin_fixture(),
          session: Auth.session_payload(admin.id, admin.fingerprint)
        )

      assert redirected_to(conn) == "/login"
    end

    test "an expired session is refused" do
      admin = admin_fixture()

      payload =
        admin.id
        |> Auth.session_payload(admin.fingerprint)
        |> Map.put("authenticated_at", System.system_time(:second) - 13 * 3600)

      conn = visit("/", certificate: admin, session: payload)

      assert redirected_to(conn) == "/login"
    end

    test "the query string is kept for after the login" do
      conn = visit("/domains?domain=a.example.com")

      assert get_session(conn, "return_to") == "/domains?domain=a.example.com"
    end
  end

  describe "with both factors" do
    test "the request goes through with its scope assigned" do
      admin = admin_fixture(:monitor, ["a.example.com"])
      conn = visit("/", admin: admin)

      refute conn.halted
      assert conn.assigns.current_scope.admin.id == admin.id
      assert conn.assigns.current_scope.admin.level == :monitor
      assert conn.assigns.current_scope.admin.domains == ["a.example.com"]
    end

    test "a revoked workstation loses access" do
      admin = admin_fixture()
      {:ok, _} = Auth.issue_certificate(admin.id, "second poste")
      {:ok, _} = Auth.revoke_certificate(admin.id, admin.fingerprint)

      assert redirected_to(visit("/", admin: admin)) == "/login"
    end

    test "an account disabled during the session loses access" do
      admin = admin_fixture()
      {:ok, _} = Auth.set_enabled(admin.id, false)

      assert redirected_to(visit("/", admin: admin)) == "/login"
    end
  end

  describe "account management" do
    test "a global administrator is let through" do
      conn = visit("/admins", admin: admin_fixture(:admin, :all), require: :manage_accounts)

      refute conn.halted
    end

    test "a domain administrator is not" do
      conn =
        visit("/admins",
          admin: admin_fixture(:admin, ["a.example.com"]),
          require: :manage_accounts
        )

      assert redirected_to(conn) == "/"
    end

    test "a global monitor is not" do
      conn = visit("/admins", admin: admin_fixture(:monitor, :all), require: :manage_accounts)

      assert redirected_to(conn) == "/"
    end
  end

  describe "the router" do
    @public ["/enroll", "/login", "/locale/:locale", "/session"]

    test "answers no page of the application without both factors", %{conn: conn} do
      for route <- KelescopeWeb.Router.__routes__(),
          route.verb == :get,
          route.path not in @public,
          not String.starts_with?(route.path, "/dev") do
        path = String.replace(route.path, ~r/:[a-z_0-9]+/, "x")
        answer = get(conn, path)

        assert redirected_to(answer) == "/login",
               "#{route.path} answered #{answer.status} without a certificate"
      end
    end
  end

  defp visit(path, opts \\ []) do
    admin = opts[:admin]
    certificate = opts[:certificate] || admin
    session = opts[:session] || (admin && Auth.session_payload(admin.id, admin.fingerprint))

    build_conn(:get, path)
    |> then(fn conn -> if certificate, do: with_certificate(conn, certificate), else: conn end)
    |> Plug.Test.init_test_session(session || %{})
    |> Phoenix.Controller.fetch_flash()
    |> AuthPlug.call(Keyword.get(opts, :require, :authenticated))
  end
end
