defmodule KelescopeWeb.AuthHook do
  @moduledoc """
  Live counterpart of `KelescopeWeb.Plugs.Auth`.

  It checks the same two factors at mount, then keeps watching: a revoked
  workstation or a disabled account closes the open live session instead of
  waiting for the next mount.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Kelescope.Auth
  alias Kelescope.Auth.ClientCert
  alias Kelescope.Auth.Scope

  @doc """
  Extra live session data, filled from the HTTP request that served the page.

  The static render happens before the socket exists, so the certificate of
  the connected mount is not available yet. Everything the page decides on its
  own is re-checked against `:peer_data` as soon as the socket connects.
  """
  def peer_session(conn) do
    %{"cert_fingerprint" => ClientCert.fingerprint(conn), "request_host" => conn.host}
  end

  @doc """
  Fingerprint of the certificate behind the socket.
  """
  def fingerprint(socket, session) do
    if connected?(socket) do
      socket |> get_connect_info(:peer_data) |> ClientCert.fingerprint()
    else
      session["cert_fingerprint"]
    end
  end

  def on_mount(requirement, _params, session, socket) do
    socket
    |> assign(:current_scope, scope(socket, session))
    |> authorize(requirement)
  end

  defp scope(socket, session) do
    if Auth.dev_mode?() do
      Scope.dev()
    else
      case Auth.resolve(fingerprint(socket, session), session) do
        {:ok, scope} -> scope
        _other -> nil
      end
    end
  end

  defp authorize(socket, :none), do: {:cont, socket}

  defp authorize(%{assigns: %{current_scope: nil}} = socket, _requirement) do
    {:halt, redirect(socket, to: "/login")}
  end

  defp authorize(socket, :authenticated), do: {:cont, watch(socket)}

  defp authorize(socket, action) do
    if Scope.can?(socket.assigns.current_scope, action) do
      {:cont, watch(socket)}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  # A live session outlives the request that opened it: keep checking the
  # account behind it, and drop the socket as soon as it stops being valid.
  defp watch(socket) do
    if connected?(socket) do
      Auth.subscribe()
      attach_hook(socket, :auth_watch, :handle_info, &recheck/2)
    else
      socket
    end
  end

  # The hook owns this subscription, so it swallows the message. A page never
  # subscribed to the account topic and has no clause matching it: forwarding
  # would crash every open page as soon as any account changes.
  defp recheck({message, id}, socket)
       when message in [:account_changed, :account_deleted] do
    scope = socket.assigns.current_scope

    if match?(%Scope{dev?: false}, scope) and Scope.id(scope) == id do
      case Auth.authenticate_certificate(scope.certificate.fingerprint) do
        {:ok, account, _certificate} ->
          {:halt, assign(socket, :current_scope, Scope.new(account, scope.certificate))}

        {:error, _reason} ->
          {:halt,
           socket |> put_flash(:error, "Votre accès a été révoqué.") |> redirect(to: "/login")}
      end
    else
      {:halt, socket}
    end
  end

  defp recheck(_message, socket), do: {:cont, socket}
end
