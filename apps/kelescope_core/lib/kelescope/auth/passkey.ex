defmodule Kelescope.Auth.Passkey do
  @moduledoc """
  WebAuthn ceremonies, on top of `Wax`.

  User verification is always required: the passkey proves the person, not just
  the presence of an authenticator. Attestation is `none`, since the workstation
  is already proven by its client certificate.
  """

  @timeout_ms 120_000

  @doc """
  Options handed to `navigator.credentials.create` for a new passkey.
  """
  def registration_challenge(account) do
    Wax.new_registration_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "required",
      attestation: "none",
      trusted_attestation_types: [:none]
    )
    |> then(&{&1, registration_options(&1, account)})
  end

  defp registration_options(challenge, account) do
    %{
      "challenge" => encode(challenge.bytes),
      "rp" => %{"id" => challenge.rp_id, "name" => "kelescope"},
      "user" => %{
        "id" => encode(account.id),
        "name" => account.id,
        "displayName" => account.id
      },
      "pubKeyCredParams" => [
        %{"type" => "public-key", "alg" => -7},
        %{"type" => "public-key", "alg" => -257}
      ],
      "authenticatorSelection" => %{
        "userVerification" => "required",
        "residentKey" => "preferred"
      },
      "attestation" => "none",
      "timeout" => @timeout_ms,
      "excludeCredentials" => credential_descriptors(account)
    }
  end

  @doc """
  Verifies the browser answer to a registration ceremony.
  """
  @spec verify_registration(map(), Wax.Challenge.t()) :: {:ok, map()} | {:error, term()}
  def verify_registration(response, challenge) do
    with {:ok, attestation_object} <- decode(response["response"]["attestationObject"]),
         {:ok, client_data_json} <- decode(response["response"]["clientDataJSON"]),
         {:ok, {authenticator_data, _attestation}} <-
           Wax.register(attestation_object, client_data_json, challenge) do
      %{
        credential_id: credential_id,
        credential_public_key: public_key,
        aaguid: aaguid
      } = authenticator_data.attested_credential_data

      {:ok,
       %{
         credential_id: credential_id,
         public_key: public_key,
         aaguid: aaguid,
         sign_count: authenticator_data.sign_count
       }}
    end
  end

  @doc """
  Options handed to `navigator.credentials.get`. The certificate already named
  the account, so the allowed credentials are its passkeys.
  """
  def authentication_challenge(account) do
    Wax.new_authentication_challenge(
      origin: origin(),
      rp_id: rp_id(),
      user_verification: "required",
      allow_credentials: allow_credentials(account)
    )
    |> then(&{&1, authentication_options(&1, account)})
  end

  defp authentication_options(challenge, account) do
    %{
      "challenge" => encode(challenge.bytes),
      "rpId" => challenge.rp_id,
      "userVerification" => "required",
      "timeout" => @timeout_ms,
      "allowCredentials" => credential_descriptors(account)
    }
  end

  @doc """
  Verifies the browser answer to an authentication ceremony and returns the
  credential that signed, with its new signature counter.
  """
  @spec verify_authentication(map(), Wax.Challenge.t()) :: {:ok, map()} | {:error, term()}
  def verify_authentication(response, challenge) do
    with {:ok, credential_id} <- decode(response["rawId"] || response["id"]),
         {:ok, authenticator_data} <- decode(response["response"]["authenticatorData"]),
         {:ok, signature} <- decode(response["response"]["signature"]),
         {:ok, client_data_json} <- decode(response["response"]["clientDataJSON"]),
         {:ok, verified} <-
           Wax.authenticate(
             credential_id,
             authenticator_data,
             signature,
             client_data_json,
             challenge
           ) do
      {:ok, %{credential_id: credential_id, sign_count: verified.sign_count}}
    end
  end

  @doc """
  Origin the browser must report. It comes from the endpoint URL, so it follows
  `PHX_HOST`.
  """
  def origin, do: KelescopeWeb.Endpoint.url()

  def rp_id, do: KelescopeWeb.Endpoint.config(:url)[:host]

  defp allow_credentials(account) do
    Enum.map(account.passkeys, &{&1.credential_id, &1.public_key})
  end

  defp credential_descriptors(account) do
    Enum.map(account.passkeys, fn passkey ->
      %{"type" => "public-key", "id" => encode(passkey.credential_id)}
    end)
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)

  defp decode(nil), do: {:error, :missing_field}

  defp decode(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_encoding}
    end
  end
end
