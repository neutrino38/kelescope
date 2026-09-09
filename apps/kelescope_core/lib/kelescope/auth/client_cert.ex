defmodule Kelescope.Auth.ClientCert do
  @moduledoc """
  Client certificate presented in the TLS handshake.

  The TLS layer decides nothing: `verify_fun/3` accepts whatever the browser
  sends, and the application compares its fingerprint to the store. A revoked
  or expired certificate then gets an explanatory page instead of an
  unreadable TLS alert (ADR-004).
  """

  alias Kelescope.Auth.CA

  def verify_fun(_certificate, {:bad_cert, _reason}, state), do: {:valid, state}
  def verify_fun(_certificate, {:extension, _extension}, state), do: {:unknown, state}
  def verify_fun(_certificate, :valid, state), do: {:valid, state}
  def verify_fun(_certificate, :valid_peer, state), do: {:valid, state}

  @doc """
  Fingerprint of the certificate carried by the connection, `nil` when the
  browser presented none.
  """
  @spec fingerprint(Plug.Conn.t() | map() | nil) :: String.t() | nil
  def fingerprint(%Plug.Conn{} = conn), do: conn |> Plug.Conn.get_peer_data() |> fingerprint()
  def fingerprint(%{ssl_cert: der}) when is_binary(der), do: CA.fingerprint(der)
  def fingerprint(_peer_data), do: nil
end
