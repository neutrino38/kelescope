defmodule KelescopeWeb.AuthHookTest do
  use KelescopeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kelescope.Auth

  test "a live mount without a certificate goes to the login page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/account")
  end

  test "a live mount with an unknown certificate goes to the login page", %{conn: conn} do
    conn = with_certificate(conn, stray_certificate())

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/account")
  end

  test "a live mount with a certificate but no session goes to the login page", %{conn: conn} do
    conn = with_certificate(conn, admin_fixture())

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/account")
  end

  test "a live mount with both factors is served", %{conn: conn} do
    admin = admin_fixture()

    assert {:ok, _view, html} = conn |> log_in(admin) |> live(~p"/account")
    assert html =~ admin.id
  end

  test "revoking the workstation cuts the open live session", %{conn: conn} do
    admin = admin_fixture()
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/account")

    {:ok, _} = Auth.issue_certificate(admin.id, "autre poste")
    {:ok, _} = Auth.revoke_certificate(admin.id, admin.fingerprint)

    assert_redirect(view, "/login", 5000)
  end

  test "disabling the account cuts the open live session", %{conn: conn} do
    admin = admin_fixture()
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/account")

    {:ok, _} = Auth.set_enabled(admin.id, false)

    assert_redirect(view, "/login", 5000)
  end

  test "deleting the account cuts the open live session", %{conn: conn} do
    admin = admin_fixture(:monitor, :all)
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/account")

    {:ok, _} = Auth.delete_account(admin.id)

    assert_redirect(view, "/login", 5000)
  end

  test "a change to another account leaves the live session alone", %{conn: conn} do
    admin = admin_fixture()
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/account")

    {:ok, _} = Auth.invite(admin_fixture().id)

    assert render(view) =~ admin.id
  end

  describe "the global administrator page" do
    test "is served to a global administrator", %{conn: conn} do
      assert {:ok, _view, html} = conn |> log_in_admin(:admin, :all) |> live(~p"/admins")
      assert html =~ "Comptes administrateurs"
    end

    test "is refused to a domain administrator", %{conn: conn} do
      conn = log_in_admin(conn, :admin, ["a.example.com"])

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admins")
    end

    test "is refused to a global monitor", %{conn: conn} do
      conn = log_in_admin(conn, :monitor, :all)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admins")
    end
  end
end
