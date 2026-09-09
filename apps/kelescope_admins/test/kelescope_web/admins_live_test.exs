defmodule KelescopeWeb.AdminsLiveTest do
  use KelescopeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kelescope.Auth

  setup %{conn: conn} do
    admin = admin_fixture(:admin, :all)
    %{conn: log_in(conn, admin), admin: admin}
  end

  test "lists the accounts with their role and their means of access", %{
    conn: conn,
    admin: admin
  } do
    {:ok, _view, html} = live(conn, ~p"/admins")

    assert html =~ admin.id
    assert html =~ "administrateur"
    assert html =~ "tous domaines"
  end

  test "creates an account and shows its invitation code once", %{conn: conn} do
    id = "created-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, ~p"/admins")

    html =
      render_submit(view, "create", %{
        "admin_id" => id,
        "level" => "monitor",
        "reach" => "domains",
        "domains" => ["example.com", "test.local"]
      })

    assert html =~ "Code d&#39;invitation de #{id}"
    assert html =~ ~s(id="account-#{id}")

    code = code_from(html)
    assert {:ok, account} = Auth.fetch_account(id)
    assert account.level == :monitor
    assert account.scope == ["example.com", "test.local"]
    assert {:ok, _} = Auth.redeem_invitation(id, code)

    assert render_click(view, "dismiss_invitation") =~ id
    refute render(view) =~ "Code d&#39;invitation de #{id}"
  end

  test "refuses a malformed identifier", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admins")

    html =
      render_submit(view, "create", %{
        "admin_id" => "Prénom Nom",
        "level" => "monitor",
        "scope" => "all"
      })

    assert html =~ "Identifiant invalide"
  end

  test "resetting an account issues a new code and invalidates the old one", %{conn: conn} do
    other = admin_fixture(:monitor, :all)
    {:ok, first} = Auth.invite(other.id)
    {:ok, view, _html} = live(conn, ~p"/admins")

    html = render_click(view, "invite", %{"id" => other.id})
    second = code_from(html)

    assert first != second
    assert Auth.redeem_invitation(other.id, first) == {:error, :invalid_invitation}
    assert {:ok, _} = Auth.redeem_invitation(other.id, second)
  end

  test "changes the role of an account", %{conn: conn} do
    other = admin_fixture(:monitor, :all)
    {:ok, view, _html} = live(conn, ~p"/admins")

    render_click(view, "edit", %{"id" => other.id})

    render_submit(view, "update_role", %{
      "admin_id" => other.id,
      "level" => "admin",
      "reach" => "domains",
      "domains" => ["example.com"]
    })

    assert {:ok, account} = Auth.fetch_account(other.id)
    assert account.level == :admin
    assert account.scope == ["example.com"]
  end

  test "offers the domains kelixip serves, instead of asking for typing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admins")

    for name <- ["example.com", "test.local", "throwaway.local"] do
      assert has_element?(view, ~s|input[type="checkbox"][name="domains[]"][value="#{name}"]|)
    end

    refute has_element?(view, ~s|input[name="scope"]|)
  end

  test "gives the whole instance when that reach is chosen", %{conn: conn} do
    id = "created-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, ~p"/admins")

    render_submit(view, "create", %{
      "admin_id" => id,
      "level" => "admin",
      "reach" => "all",
      "domains" => ["example.com"]
    })

    assert {:ok, %{scope: :all}} = Auth.fetch_account(id)
  end

  test "refuses a scope with no domain ticked", %{conn: conn} do
    id = "created-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, ~p"/admins")

    html = render_submit(view, "create", %{"admin_id" => id, "level" => "monitor"})

    assert html =~ "Portée invalide."
    assert Auth.fetch_account(id) == :error
  end

  test "keeps a domain that kelixip no longer serves visible and ticked", %{conn: conn} do
    other = admin_fixture(:monitor, ["example.com", "gone.example.com"])
    {:ok, view, _html} = live(conn, ~p"/admins")

    render_click(view, "edit", %{"id" => other.id})

    assert has_element?(
             view,
             ~s|input[type="checkbox"][value="gone.example.com"][checked]|
           )

    assert render(view) =~ "non servi"
  end

  test "disables then re-enables an account", %{conn: conn} do
    other = admin_fixture(:monitor, :all)
    {:ok, view, _html} = live(conn, ~p"/admins")

    render_click(view, "toggle_enabled", %{"id" => other.id, "enabled" => "false"})
    assert {:ok, %{enabled: false}} = Auth.fetch_account(other.id)

    render_click(view, "toggle_enabled", %{"id" => other.id, "enabled" => "true"})
    assert {:ok, %{enabled: true}} = Auth.fetch_account(other.id)
  end

  test "deletes an account", %{conn: conn} do
    other = admin_fixture(:monitor, :all)
    {:ok, view, _html} = live(conn, ~p"/admins")

    render_click(view, "ask_delete", %{"id" => other.id})
    render_submit(view, "delete", %{"admin_id" => other.id})

    assert Auth.fetch_account(other.id) == :error
  end

  test "serves the page in English when the session asks for it", %{conn: conn, admin: admin} do
    {:ok, view, html} =
      conn
      |> Plug.Test.init_test_session(locale: "en")
      |> live(~p"/admins")

    assert html =~ "Administrator accounts"
    refute html =~ "Comptes administrateurs"

    assert render_submit(view, "delete", %{"admin_id" => admin.id}) =~
             "You cannot delete your own account."
  end

  test "shows a flash raised by the authentication layer", %{conn: conn} do
    {:ok, _view, html} =
      conn
      |> Plug.Test.init_test_session(%{"phoenix_flash" => %{"error" => "Accès coupé"}})
      |> live(~p"/admins")

    assert html =~ "Accès coupé"
  end

  test "refuses to delete one's own account", %{conn: conn, admin: admin} do
    # A second global administrator, so the refusal can only come from the
    # self-deletion rule and not from the last-global-admin invariant.
    keeper = admin_fixture(:admin, :all)
    {:ok, view, _html} = live(conn, ~p"/admins")

    refute has_element?(view, ~s|#account-#{admin.id} button[phx-click="ask_delete"]|)
    assert has_element?(view, ~s|#account-#{keeper.id} button[phx-click="ask_delete"]|)

    html = render_submit(view, "delete", %{"admin_id" => admin.id})

    assert html =~ "Vous ne pouvez pas supprimer votre propre compte."
    assert {:ok, _account} = Auth.fetch_account(admin.id)
  end

  test "refuses to disable or demote one's own account", %{conn: conn, admin: admin} do
    # A second global administrator, so a refusal can only come from the
    # self-action rules and not from the last-global-admin invariant.
    keeper = admin_fixture(:admin, :all)
    {:ok, view, _html} = live(conn, ~p"/admins")

    refute has_element?(view, ~s|#account-#{admin.id} button[phx-click="toggle_enabled"]|)
    refute has_element?(view, ~s|#account-#{admin.id} button[phx-click="edit"]|)
    assert has_element?(view, ~s|#account-#{keeper.id} button[phx-click="toggle_enabled"]|)
    assert has_element?(view, ~s|#account-#{keeper.id} button[phx-click="edit"]|)

    html =
      render_click(view, "toggle_enabled", %{"id" => admin.id, "enabled" => "false"})

    assert html =~ "Vous ne pouvez pas désactiver votre propre compte."
    assert {:ok, %{enabled: true}} = Auth.fetch_account(admin.id)

    html =
      render_submit(view, "update_role", %{
        "admin_id" => admin.id,
        "level" => "monitor",
        "scope" => "a.example.com"
      })

    assert html =~ "Vous ne pouvez pas changer votre propre rôle."
    assert {:ok, %{level: :admin, scope: :all}} = Auth.fetch_account(admin.id)
  end

  test "revokes a workstation of another account", %{conn: conn} do
    other = admin_fixture(:monitor, :all)
    {:ok, second} = Auth.issue_certificate(other.id, "poste maison")
    {:ok, view, _html} = live(conn, ~p"/admins")

    render_click(view, "edit", %{"id" => other.id})

    render_click(view, "revoke_certificate", %{
      "id" => other.id,
      "fingerprint" => second.fingerprint
    })

    assert Auth.authenticate_certificate(second.fingerprint) == {:error, :revoked}
  end

  defp code_from(html) do
    [_, code] = Regex.run(~r|<code[^>]*>\s*([A-Z2-7]{20})\s*</code>|, html)
    code
  end
end
