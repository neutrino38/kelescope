defmodule Kelescope.Auth do
  @moduledoc """
  Accounts, invitations, passkeys and client certificates.

  Every write goes through `Kelescope.Auth.Store.update/2`, so an invariant
  checked here still holds when the account file is written: there is always at
  least one enabled global administrator, and an account never loses its last
  passkey or its last workstation.
  """

  alias Kelescope.Auth.CA
  alias Kelescope.Auth.Scope
  alias Kelescope.Auth.Store

  @topic "auth:accounts"
  @id_format ~r/^[a-z0-9._-]{2,32}$/
  @invitation_length 20

  @doc """
  PubSub topic carrying `{:account_changed, id}` and `{:account_deleted, id}`.
  A live session watches it so a revocation cuts it without waiting for the
  next mount.
  """
  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(Kelescope.PubSub, @topic)
  end

  ## Session

  @doc """
  Says what the two factors carried by a request prove.

  `fingerprint` comes from the client certificate of the TLS handshake,
  `session` from the signed cookie. A cookie without its certificate proves
  nothing, and a certificate without a fresh passkey ceremony proves only the
  workstation.
  """
  @spec resolve(String.t() | nil, map(), keyword()) ::
          {:ok, Scope.t()}
          | {:passkey_required, map(), map()}
          | {:error, :no_certificate | :unknown | :revoked | :expired | :disabled}
  def resolve(fingerprint, session, opts \\ [])

  def resolve(nil, _session, _opts), do: {:error, :no_certificate}

  def resolve(fingerprint, session, opts) do
    case authenticate_certificate(fingerprint, opts) do
      {:ok, account, certificate} ->
        if session_valid?(session, account.id, fingerprint),
          do: {:ok, Scope.new(account, certificate)},
          else: {:passkey_required, account, certificate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  A session is bound to the certificate that opened it: a stolen cookie
  replayed from another workstation is refused.
  """
  def session_valid?(session, id, fingerprint) do
    with %{"admin_id" => ^id, "cert_fp" => ^fingerprint, "authenticated_at" => at} <- session,
         true <- is_integer(at) do
      System.system_time(:second) - at < session_hours() * 3600
    else
      _ -> false
    end
  end

  @doc """
  Session payload written by `KelescopeWeb.SessionController`.
  """
  def session_payload(id, fingerprint) do
    %{
      "admin_id" => id,
      "cert_fp" => fingerprint,
      "authenticated_at" => System.system_time(:second)
    }
  end

  @doc """
  True when the instance runs without authentication. `runtime.exs` only ever
  sets this outside `:prod`, so a production release cannot turn it on.
  """
  def dev_mode?, do: Application.get_env(:kelescope_core, :auth_dev_mode, false)

  ## Reads

  def list_accounts(opts \\ []), do: Store.list(store(opts))

  def fetch_account(id, opts \\ []), do: Store.fetch(store(opts), id)

  @doc """
  Resolves a client certificate fingerprint to its account, or says why it is
  refused. The workstation identity is the fingerprint, never the issuer.
  """
  @spec authenticate_certificate(String.t(), keyword()) ::
          {:ok, map(), map()} | {:error, :unknown | :revoked | :expired | :disabled}
  def authenticate_certificate(fingerprint, opts \\ []) do
    with {:ok, account} <- unknown(Store.fetch_by_certificate(store(opts), fingerprint)),
         certificate = find_certificate(account, fingerprint),
         :ok <- usable_certificate(certificate),
         :ok <- enabled(account) do
      {:ok, account, certificate}
    end
  end

  defp unknown(:error), do: {:error, :unknown}
  defp unknown({:ok, account}), do: {:ok, account}

  defp usable_certificate(%{revoked_at: %DateTime{}}), do: {:error, :revoked}

  defp usable_certificate(certificate) do
    if DateTime.compare(certificate.expires_at, now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp enabled(%{enabled: true}), do: :ok
  defp enabled(_account), do: {:error, :disabled}

  ## Bootstrap

  @doc """
  Creates the first global administrator from the host shell. Refuses once an
  account exists, unless `force: true` rebuilds an access that was lost.
  """
  @spec bootstrap(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bootstrap(id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    result =
      write(opts, fn accounts ->
        cond do
          accounts != %{} and not force ->
            {:error, :accounts_exist}

          Map.has_key?(accounts, id) ->
            {:error, :already_taken}

          true ->
            insert_new(accounts, id, :admin, :all)
        end
      end)

    case result do
      {:ok, {_account, code}} ->
        IO.puts("""

        Account #{id} created: admin, all domains.
        Invitation code (valid #{invite_hours()} h): #{code}
        Enroll at https://#{host()}/enroll
        """)

        {:ok, code}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Accounts

  @doc """
  Creates an account and its first invitation code. The code is returned in
  clear once; only its SHA-256 is stored.
  """
  @spec create_account(map(), keyword()) :: {:ok, {map(), String.t()}} | {:error, term()}
  def create_account(attrs, opts \\ []) do
    with {:ok, id} <- validate_id(attrs[:id]),
         {:ok, level} <- validate_level(attrs[:level]),
         {:ok, scope} <- validate_scope(attrs[:scope]) do
      write(opts, fn accounts ->
        if Map.has_key?(accounts, id) do
          {:error, :already_taken}
        else
          insert_new(accounts, id, level, scope)
        end
      end)
    end
  end

  @doc """
  Issues a fresh invitation code, replacing any pending one. This is the reset
  used when someone lost their passkey or their workstation.
  """
  @spec invite(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def invite(id, opts \\ []) do
    update_account(opts, id, fn account ->
      {code, invitation} = new_invitation()
      {:ok, %{account | invitation: invitation}, code}
    end)
  end

  @doc """
  Checks an invitation code without consuming it: enrolment needs it valid
  across the passkey step and the certificate step.
  """
  @spec redeem_invitation(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :invalid_invitation}
  def redeem_invitation(id, code, opts \\ []) do
    with {:ok, account} <- ok_or(Store.fetch(store(opts), id), :invalid_invitation),
         %{hash: hash, expires_at: expires_at} <- account.invitation,
         true <- Plug.Crypto.secure_compare(hash, hash_invitation(code)),
         :gt <- DateTime.compare(expires_at, now()),
         true <- account.enabled do
      {:ok, account}
    else
      _ -> {:error, :invalid_invitation}
    end
  end

  @spec consume_invitation(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consume_invitation(id, opts \\ []) do
    update_account(opts, id, fn account -> {:ok, %{account | invitation: nil}, account} end)
  end

  @spec update_role(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_role(id, attrs, opts \\ []) do
    with {:ok, level} <- validate_level(attrs[:level]),
         {:ok, scope} <- validate_scope(attrs[:scope]) do
      write(opts, fn accounts ->
        with {:ok, account} <- ok_or(Map.fetch(accounts, id), :not_found),
             updated = %{account | level: level, scope: scope},
             :ok <- keep_a_global_admin(accounts, id, updated) do
          commit(accounts, updated)
        end
      end)
    end
  end

  @spec set_enabled(String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_enabled(id, enabled, opts \\ []) do
    write(opts, fn accounts ->
      with {:ok, account} <- ok_or(Map.fetch(accounts, id), :not_found),
           updated = %{account | enabled: enabled},
           :ok <- keep_a_global_admin(accounts, id, updated) do
        commit(accounts, updated)
      end
    end)
  end

  @spec delete_account(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def delete_account(id, opts \\ []) do
    result =
      write(opts, fn accounts ->
        with {:ok, _account} <- ok_or(Map.fetch(accounts, id), :not_found),
             :ok <- keep_a_global_admin(accounts, id, nil) do
          {:ok, Map.delete(accounts, id), id}
        end
      end)

    with {:ok, ^id} <- result do
      broadcast({:account_deleted, id})
      {:ok, id}
    end
  end

  @spec touch_login(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def touch_login(id, opts \\ []) do
    update_account(opts, id, fn account ->
      updated = %{account | last_login_at: now()}
      {:ok, updated, updated}
    end)
  end

  ## Passkeys

  @doc """
  Records a passkey. `passkey` carries the credential id, the COSE public key,
  the signature counter, the AAGUID and a label.
  """
  @spec add_passkey(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_passkey(id, passkey, opts \\ []) do
    write(opts, fn accounts ->
      with {:ok, account} <- ok_or(Map.fetch(accounts, id), :not_found),
           :ok <- credential_free(accounts, passkey.credential_id) do
        entry = %{
          credential_id: passkey.credential_id,
          public_key: passkey.public_key,
          sign_count: passkey[:sign_count] || 0,
          aaguid: passkey[:aaguid],
          label: passkey[:label] || "passkey",
          created_at: now()
        }

        commit(accounts, %{account | passkeys: account.passkeys ++ [entry]})
      end
    end)
  end

  @doc """
  Stores the signature counter reported by the authenticator. A counter going
  backwards means a cloned authenticator, and the passkey is refused.
  """
  @spec update_sign_count(String.t(), binary(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_sign_count(id, credential_id, sign_count, opts \\ []) do
    update_account(opts, id, fn account ->
      case Enum.find(account.passkeys, &(&1.credential_id == credential_id)) do
        nil ->
          {:error, :unknown_passkey}

        %{sign_count: previous} when previous > 0 and sign_count > 0 and sign_count <= previous ->
          {:error, :sign_count_regression}

        passkey ->
          passkeys =
            replace(account.passkeys, passkey, %{passkey | sign_count: sign_count})

          updated = %{account | passkeys: passkeys}
          {:ok, updated, updated}
      end
    end)
  end

  @spec revoke_passkey(String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def revoke_passkey(id, credential_id, opts \\ []) do
    update_account(opts, id, fn account ->
      remaining = Enum.reject(account.passkeys, &(&1.credential_id == credential_id))

      cond do
        remaining == account.passkeys -> {:error, :unknown_passkey}
        remaining == [] -> {:error, :last_passkey}
        true -> ok_account(%{account | passkeys: remaining})
      end
    end)
  end

  ## Client certificates

  @doc """
  Issues a client certificate for the account and records its fingerprint. The
  returned bundle and password are shown once and never stored.
  """
  @spec issue_certificate(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue_certificate(id, label, opts \\ []) do
    store = store(opts)

    with {:ok, _account} <- ok_or(Store.fetch(store, id), :not_found),
         {:ok, issued} <-
           CA.issue(Store.dir(store), host(), id, label, client_cert_days()),
         {:ok, _account} <-
           update_account(opts, id, fn account ->
             entry = %{
               fingerprint: issued.fingerprint,
               serial: issued.serial,
               label: label,
               issued_at: issued.issued_at,
               expires_at: issued.expires_at,
               revoked_at: nil
             }

             ok_account(%{account | certificates: account.certificates ++ [entry]})
           end) do
      {:ok, issued}
    end
  end

  @spec revoke_certificate(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def revoke_certificate(id, fingerprint, opts \\ []) do
    update_account(opts, id, fn account ->
      case find_certificate(account, fingerprint) do
        nil ->
          {:error, :unknown_certificate}

        %{revoked_at: %DateTime{}} ->
          {:error, :already_revoked}

        certificate ->
          if active_certificates(account) == [certificate] do
            {:error, :last_certificate}
          else
            certificates =
              replace(account.certificates, certificate, %{certificate | revoked_at: now()})

            ok_account(%{account | certificates: certificates})
          end
      end
    end)
  end

  @doc """
  Certificates that are neither revoked nor expired.
  """
  def active_certificates(account) do
    Enum.filter(account.certificates, &(usable_certificate(&1) == :ok))
  end

  def find_certificate(account, fingerprint) do
    Enum.find(account.certificates, &(&1.fingerprint == fingerprint))
  end

  ## Configuration

  @doc """
  Relying party identifier of the WebAuthn ceremonies: the host the browser
  must use. A different alias or an IP address breaks every ceremony.
  """
  def host do
    :kelescope_core
    |> Application.get_env(KelescopeWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:host, "localhost")
  end

  def client_cert_days, do: setting(:client_cert_days, 365)
  def session_hours, do: setting(:session_hours, 12)
  def invite_hours, do: setting(:invite_hours, 24)

  defp setting(key, default) do
    Application.get_env(:kelescope_core, __MODULE__, []) |> Keyword.get(key, default)
  end

  ## Internals

  defp store(opts), do: Keyword.get(opts, :store, Store)

  defp write(opts, fun) do
    case Store.update(store(opts), fun) do
      {:ok, %{id: id} = account} ->
        broadcast({:account_changed, id})
        {:ok, account}

      {:ok, {%{id: id} = account, extra}} ->
        broadcast({:account_changed, id})
        {:ok, {account, extra}}

      other ->
        other
    end
  end

  defp update_account(opts, id, fun) do
    write(opts, fn accounts ->
      with {:ok, account} <- ok_or(Map.fetch(accounts, id), :not_found),
           {:ok, updated, reply} <- fun.(account) do
        {:ok, Map.put(accounts, id, %{updated | updated_at: now()}), reply}
      end
    end)
  end

  defp commit(accounts, account) do
    updated = %{account | updated_at: now()}
    {:ok, Map.put(accounts, account.id, updated), updated}
  end

  defp ok_account(account), do: {:ok, account, account}

  defp insert_new(accounts, id, level, scope) do
    {code, invitation} = new_invitation()

    account = %{
      id: id,
      level: level,
      scope: scope,
      enabled: true,
      passkeys: [],
      certificates: [],
      invitation: invitation,
      last_login_at: nil,
      created_at: now(),
      updated_at: now()
    }

    {:ok, Map.put(accounts, id, account), {account, code}}
  end

  # There must always be a way back in: the last enabled global administrator
  # cannot be deleted, disabled, or stripped of its global level.
  defp keep_a_global_admin(accounts, id, replacement) do
    remaining =
      accounts
      |> Map.delete(id)
      |> Map.values()
      |> then(fn others -> if replacement, do: [replacement | others], else: others end)
      |> Enum.filter(&global_admin?/1)

    if remaining == [], do: {:error, :last_global_admin}, else: :ok
  end

  defp global_admin?(account) do
    account.enabled and account.level == :admin and account.scope == :all
  end

  defp credential_free(accounts, credential_id) do
    taken? =
      Enum.any?(accounts, fn {_id, account} ->
        Enum.any?(account.passkeys, &(&1.credential_id == credential_id))
      end)

    if taken?, do: {:error, :credential_taken}, else: :ok
  end

  defp new_invitation do
    code =
      @invitation_length
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(padding: false)
      |> binary_part(0, @invitation_length)

    {code, %{hash: hash_invitation(code), expires_at: DateTime.add(now(), invite_hours(), :hour)}}
  end

  defp hash_invitation(code) do
    :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
  end

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@id_format, id), do: {:ok, id}, else: {:error, :invalid_id}
  end

  defp validate_id(_id), do: {:error, :invalid_id}

  defp validate_level(level) when level in [:monitor, :admin], do: {:ok, level}
  defp validate_level("monitor"), do: {:ok, :monitor}
  defp validate_level("admin"), do: {:ok, :admin}
  defp validate_level(_level), do: {:error, :invalid_level}

  defp validate_scope(:all), do: {:ok, :all}
  defp validate_scope("all"), do: {:ok, :all}

  defp validate_scope(domains) when is_list(domains) do
    domains = domains |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    if domains == [], do: {:error, :invalid_scope}, else: {:ok, domains}
  end

  defp validate_scope(_scope), do: {:error, :invalid_scope}

  defp replace(list, old, new), do: Enum.map(list, &if(&1 == old, do: new, else: &1))

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or({:ok, value}, _reason), do: {:ok, value}

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Kelescope.PubSub, @topic, message)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
