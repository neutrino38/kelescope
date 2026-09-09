defmodule KelescopeWeb.Plugs.AuthDevModeTest do
  # :auth_dev_mode is application-wide: an async test flipping it would send
  # every other test through the dev path.
  use KelescopeWeb.ConnCase, async: false

  alias Kelescope.Auth.Scope
  alias KelescopeWeb.Plugs.Auth, as: AuthPlug

  setup do
    Application.put_env(:kelescope_core, :auth_dev_mode, true)
    on_exit(fn -> Application.delete_env(:kelescope_core, :auth_dev_mode) end)
  end

  test "hands a global administrator scope without any certificate" do
    conn =
      build_conn(:get, "/")
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> AuthPlug.call(:authenticated)

    refute conn.halted
    assert conn.assigns.current_scope.dev?
    assert Scope.can?(conn.assigns.current_scope, :manage_accounts)
  end
end
