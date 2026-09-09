defmodule Kelescope.AuthTest do
  use Kelescope.AuthCase, async: true

  import ExUnit.CaptureIO

  alias Kelescope.Auth
  alias Kelescope.Auth.Store

  describe "bootstrap/2" do
    test "creates the first global administrator", %{store: store} do
      code = capture_bootstrap("prenom.nom", store: store)

      assert {:ok, account} = Auth.fetch_account("prenom.nom", store: store)
      assert account.level == :admin
      assert account.scope == :all
      assert {:ok, ^account} = Auth.redeem_invitation("prenom.nom", code, store: store)
    end

    test "refuses once an account exists", %{store: store} do
      capture_bootstrap("prenom.nom", store: store)

      assert capture_io(fn ->
               assert Auth.bootstrap("autre.nom", store: store) == {:error, :accounts_exist}
             end) == ""
    end

    test "force: true adds one more global administrator", %{store: store} do
      capture_bootstrap("prenom.nom", store: store)
      capture_bootstrap("autre.nom", store: store, force: true)

      assert length(Auth.list_accounts(store: store)) == 2
    end
  end

  describe "invitations" do
    test "a code works once and no longer after being consumed", %{store: store} do
      {:ok, {_account, code}} = Auth.create_account(monitor(), store: store)

      assert {:ok, _} = Auth.redeem_invitation("prenom.nom", code, store: store)
      assert {:ok, _} = Auth.consume_invitation("prenom.nom", store: store)

      assert Auth.redeem_invitation("prenom.nom", code, store: store) ==
               {:error, :invalid_invitation}
    end

    test "an expired code is refused", %{store: store} do
      {:ok, {_account, code}} = Auth.create_account(monitor(), store: store)
      expire_invitation(store, "prenom.nom")

      assert Auth.redeem_invitation("prenom.nom", code, store: store) ==
               {:error, :invalid_invitation}
    end

    test "a wrong code is refused", %{store: store} do
      {:ok, _} = Auth.create_account(monitor(), store: store)

      assert Auth.redeem_invitation("prenom.nom", "NOPE", store: store) ==
               {:error, :invalid_invitation}
    end

    test "a disabled account cannot redeem", %{store: store} do
      capture_bootstrap("global.admin", store: store)
      {:ok, {_account, code}} = Auth.create_account(monitor(), store: store)
      {:ok, _} = Auth.set_enabled("prenom.nom", false, store: store)

      assert Auth.redeem_invitation("prenom.nom", code, store: store) ==
               {:error, :invalid_invitation}
    end

    test "invite/1 replaces the pending code", %{store: store} do
      {:ok, {_account, first}} = Auth.create_account(monitor(), store: store)
      {:ok, second} = Auth.invite("prenom.nom", store: store)

      assert first != second

      assert Auth.redeem_invitation("prenom.nom", first, store: store) ==
               {:error, :invalid_invitation}

      assert {:ok, _} = Auth.redeem_invitation("prenom.nom", second, store: store)
    end
  end

  describe "the last global administrator" do
    setup %{store: store} do
      capture_bootstrap("global.admin", store: store)
      :ok
    end

    test "cannot be disabled", %{store: store} do
      assert Auth.set_enabled("global.admin", false, store: store) ==
               {:error, :last_global_admin}
    end

    test "cannot be deleted", %{store: store} do
      assert Auth.delete_account("global.admin", store: store) == {:error, :last_global_admin}
    end

    test "cannot lose its global level", %{store: store} do
      assert Auth.update_role("global.admin", %{level: :admin, scope: ["a.example.com"]},
               store: store
             ) == {:error, :last_global_admin}

      assert Auth.update_role("global.admin", %{level: :monitor, scope: :all}, store: store) ==
               {:error, :last_global_admin}
    end

    test "gives way once another one exists", %{store: store} do
      capture_bootstrap("second.admin", store: store, force: true)

      assert {:ok, _} = Auth.set_enabled("global.admin", false, store: store)
      assert {:ok, "global.admin"} = Auth.delete_account("global.admin", store: store)
    end
  end

  describe "passkeys" do
    setup %{store: store} do
      {:ok, _} = Auth.create_account(monitor(), store: store)
      {:ok, _} = Auth.add_passkey("prenom.nom", passkey(<<1>>), store: store)
      :ok
    end

    test "the same credential cannot be claimed twice", %{store: store} do
      assert Auth.add_passkey("prenom.nom", passkey(<<1>>), store: store) ==
               {:error, :credential_taken}
    end

    test "the last passkey cannot be revoked", %{store: store} do
      assert Auth.revoke_passkey("prenom.nom", <<1>>, store: store) == {:error, :last_passkey}

      {:ok, _} = Auth.add_passkey("prenom.nom", passkey(<<2>>), store: store)

      assert {:ok, account} = Auth.revoke_passkey("prenom.nom", <<1>>, store: store)
      assert [%{credential_id: <<2>>}] = account.passkeys
    end

    test "a signature counter going backwards is refused", %{store: store} do
      assert {:ok, _} = Auth.update_sign_count("prenom.nom", <<1>>, 7, store: store)

      assert Auth.update_sign_count("prenom.nom", <<1>>, 7, store: store) ==
               {:error, :sign_count_regression}

      assert Auth.update_sign_count("prenom.nom", <<1>>, 3, store: store) ==
               {:error, :sign_count_regression}

      assert {:ok, _} = Auth.update_sign_count("prenom.nom", <<1>>, 8, store: store)
    end

    test "a counter stuck at zero is accepted", %{store: store} do
      {:ok, _} = Auth.add_passkey("prenom.nom", passkey(<<2>>), store: store)

      assert {:ok, _} = Auth.update_sign_count("prenom.nom", <<2>>, 0, store: store)
      assert {:ok, _} = Auth.update_sign_count("prenom.nom", <<2>>, 0, store: store)
    end
  end

  describe "authenticate_certificate/1" do
    setup %{store: store} do
      {:ok, _} = Auth.create_account(monitor(), store: store)
      {:ok, issued} = Auth.issue_certificate("prenom.nom", "poste bureau", store: store)
      %{fingerprint: issued.fingerprint}
    end

    test "accepts a registered, live certificate", %{store: store, fingerprint: fingerprint} do
      assert {:ok, %{id: "prenom.nom"}, %{label: "poste bureau"}} =
               Auth.authenticate_certificate(fingerprint, store: store)
    end

    test "refuses an unknown fingerprint", %{store: store} do
      assert Auth.authenticate_certificate("deadbeef", store: store) == {:error, :unknown}
    end

    test "refuses a revoked certificate", %{store: store, fingerprint: fingerprint} do
      {:ok, second} = Auth.issue_certificate("prenom.nom", "poste maison", store: store)
      {:ok, _} = Auth.revoke_certificate("prenom.nom", fingerprint, store: store)

      assert Auth.authenticate_certificate(fingerprint, store: store) == {:error, :revoked}
      assert {:ok, _, _} = Auth.authenticate_certificate(second.fingerprint, store: store)
    end

    test "refuses an expired certificate", %{store: store, fingerprint: fingerprint} do
      expire_certificate(store, "prenom.nom", fingerprint)

      assert Auth.authenticate_certificate(fingerprint, store: store) == {:error, :expired}
    end

    test "refuses a disabled account", %{store: store, fingerprint: fingerprint} do
      capture_bootstrap("global.admin", store: store, force: true)
      {:ok, _} = Auth.set_enabled("prenom.nom", false, store: store)

      assert Auth.authenticate_certificate(fingerprint, store: store) == {:error, :disabled}
    end

    test "the last live certificate cannot be revoked", %{store: store, fingerprint: fingerprint} do
      assert Auth.revoke_certificate("prenom.nom", fingerprint, store: store) ==
               {:error, :last_certificate}
    end
  end

  describe "validation" do
    test "an identifier outside the format is refused", %{store: store} do
      assert Auth.create_account(%{monitor() | id: "Prénom Nom"}, store: store) ==
               {:error, :invalid_id}

      assert Auth.create_account(%{monitor() | id: "a"}, store: store) == {:error, :invalid_id}
    end

    test "an empty domain list is refused", %{store: store} do
      assert Auth.create_account(%{monitor() | scope: []}, store: store) ==
               {:error, :invalid_scope}

      assert Auth.create_account(%{monitor() | scope: ["  "]}, store: store) ==
               {:error, :invalid_scope}
    end

    test "an identifier is taken once", %{store: store} do
      {:ok, _} = Auth.create_account(monitor(), store: store)
      assert Auth.create_account(monitor(), store: store) == {:error, :already_taken}
    end
  end

  test "a change is broadcast on the account topic", %{store: store} do
    Auth.subscribe()
    {:ok, _} = Auth.create_account(monitor(), store: store)

    assert_receive {:account_changed, "prenom.nom"}
  end

  defp monitor, do: %{id: "prenom.nom", level: :monitor, scope: ["a.example.com"]}

  defp passkey(credential_id) do
    %{
      credential_id: credential_id,
      public_key: %{1 => 2},
      sign_count: 0,
      aaguid: <<0::128>>,
      label: "clé"
    }
  end

  defp capture_bootstrap(id, opts) do
    parent = self()

    capture_io(fn -> send(parent, {:bootstrap, Auth.bootstrap(id, opts)}) end)

    receive do
      {:bootstrap, {:ok, code}} -> code
    after
      0 -> flunk("bootstrap #{id} failed")
    end
  end

  defp expire_invitation(store, id) do
    Store.update(store, fn accounts ->
      account = accounts[id]
      past = DateTime.add(DateTime.utc_now(), -1, :hour) |> DateTime.truncate(:second)
      updated = %{account | invitation: %{account.invitation | expires_at: past}}
      {:ok, Map.put(accounts, id, updated), updated}
    end)
  end

  defp expire_certificate(store, id, fingerprint) do
    Store.update(store, fn accounts ->
      account = accounts[id]
      past = DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.truncate(:second)

      certificates =
        Enum.map(account.certificates, fn certificate ->
          if certificate.fingerprint == fingerprint,
            do: %{certificate | expires_at: past},
            else: certificate
        end)

      updated = %{account | certificates: certificates}
      {:ok, Map.put(accounts, id, updated), updated}
    end)
  end
end
