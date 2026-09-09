defmodule Kelescope.Auth.StoreTest do
  use ExUnit.Case, async: true

  import Kelescope.AuthCase

  alias Kelescope.Auth.Store

  setup do
    dir = auth_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a missing file gives an empty store, not an error", %{dir: dir} do
    store = start_store(dir)

    assert Store.list(store) == []
    refute File.exists?(Store.path(dir))
  end

  test "the directory is created private", %{dir: dir} do
    File.rm_rf!(dir)
    start_store(dir)

    %File.Stat{mode: mode} = File.stat!(dir)
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  test "a written account comes back after a reload", %{dir: dir} do
    store = start_store(dir)
    {:ok, {account, _code}} = Kelescope.Auth.create_account(role(), store: store)

    {:ok, _} =
      Kelescope.Auth.add_passkey(
        account.id,
        %{
          credential_id: <<1, 2, 3>>,
          public_key: %{1 => 2, -1 => <<9, 9>>},
          sign_count: 4,
          aaguid: <<0::128>>,
          label: "clé jaune"
        },
        store: store
      )

    stop_supervised!(store)
    reloaded = start_store(dir)

    assert {:ok, again} = Store.fetch(reloaded, "prenom.nom")
    assert again.level == :admin
    assert again.scope == ["a.example.com"]
    assert [passkey] = again.passkeys
    assert passkey.credential_id == <<1, 2, 3>>
    assert passkey.public_key == %{1 => 2, -1 => <<9, 9>>}
    assert passkey.sign_count == 4
    assert passkey.aaguid == <<0::128>>
    assert %DateTime{} = again.created_at
  end

  test "a stale temporary file is never read", %{dir: dir} do
    store = start_store(dir)
    {:ok, _} = Kelescope.Auth.create_account(role(), store: store)
    File.write!(Store.path(dir) <> ".tmp", "{ not json")

    stop_supervised!(store)
    reloaded = start_store(dir)

    assert [%{id: "prenom.nom"}] = Store.list(reloaded)
  end

  test "no temporary file survives a write", %{dir: dir} do
    store = start_store(dir)
    {:ok, _} = Kelescope.Auth.create_account(role(), store: store)

    refute File.exists?(Store.path(dir) <> ".tmp")

    %File.Stat{mode: mode} = File.stat!(Store.path(dir))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a corrupt file stops the store rather than opening the service", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Store.path(dir), "{ not json")

    assert {:error, {{:auth_store_invalid, _path}, _}} =
             start_supervised({Store, name: :corrupt_store, dir: dir})
  end

  test "the certificate index resolves a fingerprint to its account", %{dir: dir} do
    store = start_store(dir)
    {:ok, _} = Kelescope.Auth.create_account(role(), store: store)
    {:ok, issued} = Kelescope.Auth.issue_certificate("prenom.nom", "poste", store: store)

    assert {:ok, %{id: "prenom.nom"}} = Store.fetch_by_certificate(store, issued.fingerprint)
    assert Store.fetch_by_certificate(store, "deadbeef") == :error
  end

  defp role, do: %{id: "prenom.nom", level: :admin, scope: ["a.example.com"]}
end
