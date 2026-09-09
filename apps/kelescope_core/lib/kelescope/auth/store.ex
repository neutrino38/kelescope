defmodule Kelescope.Auth.Store do
  @moduledoc """
  Sole writer of the account file. Reads come from an ETS table, writes go
  through this GenServer, so an invariant checked inside `update/2` still holds
  when the new state is written.

  An unreadable account file stops the supervisor: a halted service beats a
  service open to everyone.
  """
  use GenServer

  require Logger

  @version 1

  @type account :: map()
  @type accounts :: %{optional(String.t()) => account()}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    dir = Keyword.get(opts, :dir) || default_dir()

    GenServer.start_link(__MODULE__, {name, dir}, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Directory holding `admins.json`, `ca.key` and `ca.crt`.
  """
  def default_dir do
    Application.get_env(:kelescope_core, __MODULE__, [])
    |> Keyword.get(:dir, "/var/lib/kelescope/auth")
  end

  def dir(name \\ __MODULE__), do: GenServer.call(name, :dir)

  def path(dir), do: Path.join(dir, "admins.json")

  ## Reads, straight from ETS

  @spec fetch(atom(), String.t()) :: {:ok, account()} | :error
  def fetch(name \\ __MODULE__, id) do
    case :ets.lookup(name, {:account, id}) do
      [{_, account}] -> {:ok, account}
      [] -> :error
    end
  end

  @spec fetch_by_certificate(atom(), String.t()) :: {:ok, account()} | :error
  def fetch_by_certificate(name \\ __MODULE__, fingerprint) do
    case :ets.lookup(name, {:cert, fingerprint}) do
      [{_, id}] -> fetch(name, id)
      [] -> :error
    end
  end

  @spec list(atom()) :: [account()]
  def list(name \\ __MODULE__) do
    name
    |> :ets.match({{:account, :_}, :"$1"})
    |> Enum.map(fn [account] -> account end)
    |> Enum.sort_by(& &1.id)
  end

  @spec count(atom()) :: non_neg_integer()
  def count(name \\ __MODULE__), do: length(list(name))

  ## Write

  @doc """
  Runs `fun` on the whole account map inside the writer process. It returns
  `{:ok, accounts, reply}` to commit, or `{:error, reason}` to leave the store
  untouched.
  """
  @spec update(atom(), (accounts() -> {:ok, accounts(), term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def update(name \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(name, {:update, fun})
  end

  ## GenServer

  @impl true
  def init({name, dir}) do
    # The authority is created here, before the endpoint starts: its TLS
    # options point at `ca.crt`, and a fresh install has no such file yet.
    with :ok <- ensure_dir(dir),
         {:ok, _authority} <- Kelescope.Auth.CA.load_or_create(dir, Kelescope.Auth.host()),
         {:ok, accounts} <- load(path(dir)) do
      table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
      publish(table, accounts)
      {:ok, %{table: table, dir: dir, path: path(dir), accounts: accounts}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:dir, _from, state), do: {:reply, state.dir, state}

  def handle_call({:update, fun}, _from, state) do
    case fun.(state.accounts) do
      {:ok, accounts, reply} ->
        case write(state.path, accounts) do
          :ok ->
            publish(state.table, accounts)
            {:reply, {:ok, reply}, %{state | accounts: accounts}}

          {:error, reason} ->
            {:reply, {:error, {:write_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  # Never empty the table first: a reader landing between the wipe and the
  # refill would see no account at all, and the plug would bounce a valid
  # session to /login. Every login writes, so that window is not theoretical.
  # Inserting the whole list is atomic; the leftovers go afterwards.
  defp publish(table, accounts) do
    objects =
      Enum.flat_map(accounts, fn {id, account} ->
        [
          {{:account, id}, account}
          | Enum.map(account.certificates, &{{:cert, &1.fingerprint}, id})
        ]
      end)

    stale = MapSet.difference(keys(table), MapSet.new(objects, &elem(&1, 0)))

    :ets.insert(table, objects)
    Enum.each(stale, &:ets.delete(table, &1))
  end

  defp keys(table) do
    table |> :ets.select([{{:"$1", :_}, [], [:"$1"]}]) |> MapSet.new()
  end

  ## Persistence

  defp load(path) do
    case File.read(path) do
      {:ok, body} -> decode(path, body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:auth_store_unreadable, path, reason}}
    end
  end

  defp decode(path, body) do
    with {:ok, %{"accounts" => accounts}} when is_list(accounts) <- Jason.decode(body) do
      {:ok, Map.new(accounts, fn account -> {account["id"], decode_account(account)} end)}
    else
      other ->
        Logger.error("invalid account file #{path}: #{inspect(other)}")
        {:error, {:auth_store_invalid, path}}
    end
  rescue
    error ->
      Logger.error("invalid account file #{path}: #{Exception.message(error)}")
      {:error, {:auth_store_invalid, path}}
  end

  defp write(path, accounts) do
    body =
      Jason.encode_to_iodata!(
        %{
          "version" => @version,
          "accounts" =>
            accounts |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&encode_account/1)
        },
        pretty: true
      )

    tmp = path <> ".tmp"

    with {:ok, fd} <- :file.open(tmp, [:write, :raw, :binary]),
         :ok <- :file.write(fd, body),
         :ok <- :file.sync(fd),
         :ok <- :file.close(fd),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, path)
    end
  end

  ## JSON shape

  defp encode_account(account) do
    %{
      "id" => account.id,
      "level" => Atom.to_string(account.level),
      "scope" => encode_scope(account.scope),
      "enabled" => account.enabled,
      "passkeys" => Enum.map(account.passkeys, &encode_passkey/1),
      "certificates" => Enum.map(account.certificates, &encode_certificate/1),
      "invitation" => encode_invitation(account.invitation),
      "last_login_at" => encode_time(account.last_login_at),
      "created_at" => encode_time(account.created_at),
      "updated_at" => encode_time(account.updated_at)
    }
  end

  defp decode_account(json) do
    %{
      id: json["id"],
      level: decode_level(json["level"]),
      scope: decode_scope(json["scope"]),
      enabled: json["enabled"] != false,
      passkeys: Enum.map(json["passkeys"] || [], &decode_passkey/1),
      certificates: Enum.map(json["certificates"] || [], &decode_certificate/1),
      invitation: decode_invitation(json["invitation"]),
      last_login_at: decode_time(json["last_login_at"]),
      created_at: decode_time(json["created_at"]),
      updated_at: decode_time(json["updated_at"])
    }
  end

  defp encode_scope(:all), do: "all"
  defp encode_scope(domains) when is_list(domains), do: domains

  defp decode_scope("all"), do: :all
  defp decode_scope(domains) when is_list(domains), do: domains

  defp decode_level("admin"), do: :admin
  defp decode_level(_), do: :monitor

  defp encode_passkey(passkey) do
    %{
      "credential_id" => Base.url_encode64(passkey.credential_id, padding: false),
      "public_key" => encode_cose_key(passkey.public_key),
      "sign_count" => passkey.sign_count,
      "aaguid" => passkey.aaguid && Base.encode16(passkey.aaguid, case: :lower),
      "label" => passkey.label,
      "created_at" => encode_time(passkey.created_at)
    }
  end

  defp decode_passkey(json) do
    %{
      credential_id: Base.url_decode64!(json["credential_id"], padding: false),
      public_key: decode_cose_key(json["public_key"]),
      sign_count: json["sign_count"] || 0,
      aaguid: json["aaguid"] && Base.decode16!(json["aaguid"], case: :mixed),
      label: json["label"],
      created_at: decode_time(json["created_at"])
    }
  end

  # A COSE key is a map of integer labels to integers or raw bytes. Neither
  # survives JSON as such, hence the tagged list.
  defp encode_cose_key(cose_key) do
    Enum.map(cose_key, fn
      {label, value} when is_integer(value) -> %{"k" => label, "i" => value}
      {label, value} when is_binary(value) -> %{"k" => label, "b" => Base.encode64(value)}
    end)
  end

  defp decode_cose_key(entries) do
    Map.new(entries, fn
      %{"k" => label, "i" => value} -> {label, value}
      %{"k" => label, "b" => value} -> {label, Base.decode64!(value)}
    end)
  end

  defp encode_certificate(certificate) do
    %{
      "fingerprint" => certificate.fingerprint,
      "serial" => certificate.serial,
      "label" => certificate.label,
      "issued_at" => encode_time(certificate.issued_at),
      "expires_at" => encode_time(certificate.expires_at),
      "revoked_at" => encode_time(certificate.revoked_at)
    }
  end

  defp decode_certificate(json) do
    %{
      fingerprint: json["fingerprint"],
      serial: json["serial"],
      label: json["label"],
      issued_at: decode_time(json["issued_at"]),
      expires_at: decode_time(json["expires_at"]),
      revoked_at: decode_time(json["revoked_at"])
    }
  end

  defp encode_invitation(nil), do: nil

  defp encode_invitation(invitation) do
    %{"hash" => invitation.hash, "expires_at" => encode_time(invitation.expires_at)}
  end

  defp decode_invitation(nil), do: nil

  defp decode_invitation(json) do
    %{hash: json["hash"], expires_at: decode_time(json["expires_at"])}
  end

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = time), do: DateTime.to_iso8601(time)

  defp decode_time(nil), do: nil

  defp decode_time(iso) do
    {:ok, time, _offset} = DateTime.from_iso8601(iso)
    time
  end
end
