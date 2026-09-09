defmodule Kelescope.Auth.PasskeyTest do
  use Kelescope.AuthCase, async: true

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey
  alias Kelescope.WebAuthnAuthenticator, as: Authenticator

  setup %{store: store} do
    {:ok, {account, _code}} =
      Auth.create_account(%{id: "prenom.nom", level: :admin, scope: :all}, store: store)

    %{account: account, authenticator: Authenticator.new()}
  end

  test "registers a passkey and reads its public key back", %{
    account: account,
    authenticator: authenticator
  } do
    {challenge, options} = Passkey.registration_challenge(account)

    assert options["rp"]["id"] == Passkey.rp_id()
    assert options["authenticatorSelection"]["userVerification"] == "required"
    assert options["attestation"] == "none"

    response = Authenticator.register(authenticator, challenge)

    assert {:ok, registered} = Passkey.verify_registration(response, challenge)
    assert registered.credential_id == authenticator.credential_id
    assert registered.public_key[3] == -7
    assert registered.sign_count == 0
  end

  test "refuses a registration answering another challenge", %{
    account: account,
    authenticator: authenticator
  } do
    {challenge, _options} = Passkey.registration_challenge(account)
    {other, _options} = Passkey.registration_challenge(account)

    response = Authenticator.register(authenticator, other)

    assert {:error, _} = Passkey.verify_registration(response, challenge)
  end

  test "authenticates against a registered passkey", %{
    store: store,
    account: account,
    authenticator: authenticator
  } do
    account = with_passkey(store, account, authenticator)
    {challenge, options} = Passkey.authentication_challenge(account)

    assert [%{"id" => id}] = options["allowCredentials"]
    assert id == Base.url_encode64(authenticator.credential_id, padding: false)

    response = Authenticator.authenticate(authenticator, challenge, 12)

    assert {:ok, verified} = Passkey.verify_authentication(response, challenge)
    assert verified.credential_id == authenticator.credential_id
    assert verified.sign_count == 12
  end

  test "refuses a signature from another authenticator", %{
    store: store,
    account: account,
    authenticator: authenticator
  } do
    account = with_passkey(store, account, authenticator)
    {challenge, _options} = Passkey.authentication_challenge(account)

    intruder = %{Authenticator.new() | credential_id: authenticator.credential_id}
    response = Authenticator.authenticate(intruder, challenge)

    assert {:error, _} = Passkey.verify_authentication(response, challenge)
  end

  test "refuses a credential that is not allowed", %{
    account: account,
    authenticator: authenticator
  } do
    {challenge, _options} = Passkey.authentication_challenge(account)
    response = Authenticator.authenticate(authenticator, challenge)

    assert {:error, _} = Passkey.verify_authentication(response, challenge)
  end

  test "a signature counter going backwards is refused by the account", %{
    store: store,
    account: account,
    authenticator: authenticator
  } do
    account = with_passkey(store, account, authenticator)
    credential_id = authenticator.credential_id

    {:ok, _} = Auth.update_sign_count(account.id, credential_id, 12, store: store)

    assert Auth.update_sign_count(account.id, credential_id, 11, store: store) ==
             {:error, :sign_count_regression}
  end

  defp with_passkey(store, account, authenticator) do
    {:ok, account} =
      Auth.add_passkey(account.id, Authenticator.passkey(authenticator), store: store)

    account
  end
end
