defmodule KelescopeWeb.SessionController do
  @moduledoc """
  Writes and clears the session cookie.

  A LiveView cannot write a cookie, so `KelescopeWeb.LoginLive` runs the
  passkey ceremony then hands over a short-lived signed token, which this
  controller exchanges for a session.
  """
  use KelescopeWeb, :controller

  alias Kelescope.Auth
  alias Kelescope.Auth.ClientCert

  @salt "session"
  @max_age 60

  @doc """
  Signs the handover token. Sixty seconds is the time it takes the browser to
  submit the form the LiveView just rendered.
  """
  def sign_token(id, fingerprint) do
    Phoenix.Token.sign(KelescopeWeb.Endpoint, @salt, %{admin_id: id, cert_fp: fingerprint})
  end

  def create(conn, %{"token" => token}) do
    if Auth.dev_mode?() do
      redirect(conn, to: "/")
    else
      open_session(conn, token)
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  defp open_session(conn, token) do
    fingerprint = ClientCert.fingerprint(conn)

    with {:ok, %{admin_id: id, cert_fp: ^fingerprint}} <-
           Phoenix.Token.verify(KelescopeWeb.Endpoint, @salt, token, max_age: @max_age),
         {:ok, _account, _certificate} <- Auth.authenticate_certificate(fingerprint) do
      return_to = get_session(conn, "return_to") || "/"
      Auth.touch_login(id)

      conn
      |> configure_session(renew: true)
      |> put_session_payload(Auth.session_payload(id, fingerprint))
      |> delete_session("return_to")
      |> redirect(to: return_to)
    else
      _other ->
        conn
        |> clear_session()
        |> configure_session(drop: true)
        |> redirect(to: "/login")
    end
  end

  defp put_session_payload(conn, payload) do
    Enum.reduce(payload, conn, fn {key, value}, conn -> put_session(conn, key, value) end)
  end
end
