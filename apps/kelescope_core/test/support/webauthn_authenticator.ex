defmodule Kelescope.WebAuthnAuthenticator do
  @moduledoc """
  Software authenticator for the tests: it answers the two WebAuthn ceremonies
  the way a security key would, so the verification path is exercised for real
  rather than mocked.
  """

  @aaguid <<0::128>>

  defstruct [:credential_id, :private_key, :sign_count]

  @doc """
  Creates an authenticator holding one ES256 credential.
  """
  def new(sign_count \\ 0) do
    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(32),
      private_key: :crypto.generate_key(:ecdh, :prime256v1),
      sign_count: sign_count
    }
  end

  @doc """
  Answer to `navigator.credentials.create`, as the JavaScript hook sends it.
  """
  def register(authenticator, challenge) do
    client_data = client_data("webauthn.create", challenge)

    auth_data =
      authenticator_data(challenge.rp_id, 0x45, authenticator.sign_count) <>
        attested_credential_data(authenticator)

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    %{
      "id" => encode(authenticator.credential_id),
      "rawId" => encode(authenticator.credential_id),
      "type" => "public-key",
      "response" => %{
        "clientDataJSON" => encode(client_data),
        "attestationObject" => encode(attestation_object)
      }
    }
  end

  @doc """
  Answer to `navigator.credentials.get`, as the JavaScript hook sends it.
  """
  def authenticate(authenticator, challenge, sign_count \\ nil) do
    client_data = client_data("webauthn.get", challenge)
    sign_count = sign_count || authenticator.sign_count + 1
    auth_data = authenticator_data(challenge.rp_id, 0x05, sign_count)
    {_public, private} = authenticator.private_key

    signature =
      :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client_data), [
        private,
        :prime256v1
      ])

    %{
      "id" => encode(authenticator.credential_id),
      "rawId" => encode(authenticator.credential_id),
      "type" => "public-key",
      "response" => %{
        "clientDataJSON" => encode(client_data),
        "authenticatorData" => encode(auth_data),
        "signature" => encode(signature),
        "userHandle" => nil
      }
    }
  end

  @doc """
  Passkey entry as `Kelescope.Auth.add_passkey/3` expects it.
  """
  def passkey(authenticator, label \\ "clé de test") do
    %{
      credential_id: authenticator.credential_id,
      public_key: cose_key(authenticator),
      sign_count: authenticator.sign_count,
      aaguid: @aaguid,
      label: label
    }
  end

  defp client_data(type, challenge) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => encode(challenge.bytes),
      "origin" => challenge.origin,
      "crossOrigin" => false
    })
  end

  defp authenticator_data(rp_id, flags, sign_count) do
    :crypto.hash(:sha256, rp_id) <> <<flags::8, sign_count::32>>
  end

  defp attested_credential_data(authenticator) do
    key = CBOR.encode(cose_key(authenticator, :cbor))

    @aaguid <>
      <<byte_size(authenticator.credential_id)::16>> <> authenticator.credential_id <> key
  end

  defp cose_key(authenticator, form \\ :raw) do
    {public, _private} = authenticator.private_key
    <<4, x::binary-size(32), y::binary-size(32)>> = public

    case form do
      :raw -> %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
      :cbor -> %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(x), -3 => bytes(y)}
    end
  end

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
end
