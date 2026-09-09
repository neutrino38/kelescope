defmodule KelescopeWeb.DevModeTest do
  # :auth_dev_mode is application-wide: an async test flipping it would send
  # every other test through the dev path.
  use KelescopeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:kelescope_core, :auth_dev_mode, true)
    on_exit(fn -> Application.delete_env(:kelescope_core, :auth_dev_mode) end)
  end

  test "serves /admins without any certificate", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, ~p"/admins")
    assert html =~ "Mode dev : authentification désactivée"
  end

  test "sends /account back to the home page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/account")
  end
end
