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
        "scope" => "a.example.com, b.example.com"
      })

    assert html =~ "Code d&#39;invitation de #{id}"
    assert html =~ ~s(id="account-#{id}")

    code = code_from(html)
    assert {:ok, account} = Auth.fetch_account(id)
    assert account.level == :monitor
    assert account.scope == ["a.example.com", "b.example.com"]
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
      "scope" => "a.example.com"
    })

    assert {:ok, account} = Auth.fetch_account(other.id)
    assert account.level == :admin
    assert account.scope == ["a.example.com"]
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
