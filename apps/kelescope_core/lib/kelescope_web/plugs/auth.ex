defmodule KelescopeWeb.Plugs.Auth do
  @moduledoc """
  Reads the client certificate and the session, then assigns `current_scope`.

  Options: `require: :none` only assigns, `require: :authenticated` demands an
  open session, `require: :manage_accounts` demands a global administrator.

  The TLS layer lets every certificate through (ADR-004), so a route left
  outside these pipelines would be public. `KelescopeWeb.Plugs.AuthTest` walks
  the router to catch that.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias Kelescope.Auth
  alias Kelescope.Auth.ClientCert
  alias Kelescope.Auth.Scope

  def init(opts), do: Keyword.get(opts, :require, :authenticated)

  def call(conn, requirement) do
    conn |> authenticate() |> authorize(requirement)
  end

  @doc """
  Assigns `current_scope` and `auth_status` without deciding anything. Runs
  once per request even when several pipelines ask for it.
  """
  def authenticate(%Plug.Conn{assigns: %{auth_status: _}} = conn), do: conn

  def authenticate(conn) do
    if Auth.dev_mode?() do
      conn |> assign(:current_scope, Scope.dev()) |> assign(:auth_status, :ok)
    else
      case Auth.resolve(ClientCert.fingerprint(conn), get_session(conn)) do
        {:ok, scope} ->
          conn |> assign(:current_scope, scope) |> assign(:auth_status, :ok)

        {:passkey_required, _account, _certificate} ->
          conn |> assign(:current_scope, nil) |> assign(:auth_status, :passkey_required)

        {:error, reason} ->
          conn |> assign(:current_scope, nil) |> assign(:auth_status, reason)
      end
    end
  end

  defp authorize(conn, :none), do: conn

  defp authorize(%Plug.Conn{assigns: %{auth_status: :ok}} = conn, :authenticated), do: conn

  defp authorize(conn, :authenticated), do: to_login(conn)

  defp authorize(%Plug.Conn{assigns: %{current_scope: %Scope{} = scope}} = conn, action) do
    if Scope.can?(scope, action) do
      conn
    else
      conn
      |> put_flash(:error, "Cette page est réservée aux administrateurs généraux.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  defp authorize(conn, _action), do: to_login(conn)

  defp to_login(conn) do
    conn
    |> put_session("return_to", return_to(conn))
    |> redirect(to: "/login")
    |> halt()
  end

  defp return_to(%Plug.Conn{method: "GET"} = conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp return_to(_conn), do: "/"
end
