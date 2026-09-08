defmodule Kelescope.Kelixip.Control do
  @moduledoc """
  RPC client for the `Kelix.Control` module exposed by a kelixip node —
  the same entry point `kelictl` uses.
  """

  @doc """
  Subscribes `pid` to scenario updates on `node`.

  Returns the current snapshot (same shape as `Kelix.Control.monitor/0`).
  `pid` then receives `{:kelix_monitor, {:upsert, row}}` and
  `{:kelix_monitor, {:remove, id}}` messages as scenarios change.
  """
  @spec subscribe_monitor(node(), pid()) :: {:ok, [map()]} | {:error, term()}
  def subscribe_monitor(node, pid) do
    case :rpc.call(node, Kelix.Control, :subscribe_monitor, [pid]) do
      {:badrpc, reason} -> {:error, reason}
      rows when is_list(rows) -> {:ok, rows}
    end
  end

  @doc """
  Uptime, counters, media-pool and node state of `node` (`kelictl status`'s
  snapshot). Unlike `subscribe_monitor/2`, there is no push side to this —
  callers poll.
  """
  @spec status(node()) :: {:ok, map()} | {:error, term()}
  def status(node) do
    case :rpc.call(node, Kelix.Control, :status, []) do
      {:badrpc, reason} -> {:error, reason}
      status when is_map(status) -> {:ok, status}
    end
  end

  @doc """
  Served domains and their properties (`kelictl domain list`), `domains.toml`
  order, each with the same live counters `domain/2` returns.
  """
  @spec list_domains(node()) :: {:ok, [map()]} | {:error, term()}
  def list_domains(node) do
    case :rpc.call(node, Kelix.Control, :domains, []) do
      {:badrpc, reason} -> {:error, reason}
      domains when is_list(domains) -> {:ok, domains}
    end
  end

  @doc """
  One domain's properties (`kelictl domain show <name>`): configuration,
  enabled functions, dial-plan, live counters. `name` is matched against the
  domain name and its aliases, case-insensitively.
  """
  @spec domain(node(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def domain(node, name) do
    case :rpc.call(node, Kelix.Control, :domain, [name]) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  @doc """
  Subscribes `pid` to domain counter updates on `node`.

  Returns the current snapshot (same shape as `list_domains/1`). `pid` then
  receives `{:kelix_domain_counter, domain, :active_calls | :registrations,
  count}` messages as either counter changes.
  """
  @spec subscribe_domain_counters(node(), pid()) :: {:ok, [map()]} | {:error, term()}
  def subscribe_domain_counters(node, pid) do
    case :rpc.call(node, Kelix.Control, :subscribe_domain_counters, [pid]) do
      {:badrpc, reason} -> {:error, reason}
      domains when is_list(domains) -> {:ok, domains}
    end
  end

  @doc """
  Subscribes `pid` to registration updates for `domain` (AORs and their
  contacts). `domain` is matched against the domain name and its aliases,
  case-insensitively; the reply's `:domain` key gives the canonical name.

  Returns the current registrations for that domain. `pid` then receives
  `{:kelix_registrations, domain, {:upsert, registration}}` and
  `{:kelix_registrations, domain, {:remove, aor}}` messages (`domain` is the
  canonical name) as registrations change.
  """
  @spec subscribe_registrations(node(), pid(), String.t()) ::
          {:ok, %{domain: String.t(), registrations: [map()]}} | {:error, :not_found | term()}
  def subscribe_registrations(node, pid, domain) do
    case :rpc.call(node, Kelix.Control, :subscribe_registrations, [pid, domain]) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  @doc """
  Removes (unregisters) one contact from an AOR (`kelictl registration remove
  <domain> <aor> <uri>`). `admin` identifies who requested it, for kelixip's
  own audit log.
  """
  @spec unregister(node(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | :notfound | {:error, term()}
  def unregister(node, domain, aor, contact_uri, admin) do
    case :rpc.call(node, Kelix.Control, :unregister, [domain, aor, contact_uri, admin]) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  @doc """
  Gracefully shuts down one running scenario instance by `id` (`kelictl
  scenario shutdown <id>`). `admin` identifies who requested it, for
  kelixip's own audit log.
  """
  @spec shutdown_scenario(node(), term(), String.t()) :: :ok | {:error, :not_found | term()}
  def shutdown_scenario(node, id, admin) do
    case :rpc.call(node, Kelix.Control, :shutdown_scenario, [id, admin]) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  @doc """
  Reloads one or more scenario scripts by name (`kelictl reload-script
  <name…>`). Returns `%{name => :ok | {:error, reason}}`, one entry per name.
  """
  @spec reload_scripts(node(), [String.t()]) ::
          {:ok, %{optional(String.t()) => term()}} | {:error, term()}
  def reload_scripts(_node, []), do: {:ok, %{}}

  def reload_scripts(node, names) do
    case :rpc.call(node, Kelix.Control, :reload_script, [names, false]) do
      {:badrpc, reason} -> {:error, reason}
      results when is_map(results) -> {:ok, results}
    end
  end

  @doc """
  Runs a module-contributed control command (`kelictl <module> <cmd> <args>`),
  the generic entry point every loadable module (e.g. `"mcu"`) reaches through.
  `args` is string-keyed, the shape `Kelix.Control.module_command/3` expects.
  """
  @spec module_command(node(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def module_command(node, module, cmd, args) do
    case :rpc.call(node, Kelix.Control, :module_command, [module, cmd, args]) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  @doc "Conferences known to the `mcu` module (`kelictl mcu conference.list`)."
  @spec list_conferences(node(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_conferences(node, filters \\ %{}) do
    module_command(node, "mcu", "conference.list", filters)
  end

  @doc "One conference and its participants (`kelictl mcu conference.show`)."
  @spec conference(node(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def conference(node, uid) do
    module_command(node, "mcu", "conference.show", %{"uid" => uid})
  end

  @doc """
  One participant, with the media server's own statistics for it — packets and
  bytes sent/received per media (`kelictl mcu participant.show`). No codec is
  reported: the media server arbitrates codecs and does not hand that choice back.
  """
  @spec participant(node(), String.t(), term()) :: {:ok, map()} | {:error, :not_found | term()}
  def participant(node, uid, part_id) do
    module_command(node, "mcu", "participant.show", %{"uid" => uid, "part_id" => part_id})
  end

  @doc """
  Creates a conference (`kelictl mcu conference.create`). `admin` identifies who
  requested it, traced in kelixip's own logs — it is not a conference field.
  """
  @spec create_conference(node(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_conference(node, attrs, admin) do
    module_command(node, "mcu", "conference.create", Map.put(attrs, "admin", admin))
  end

  @doc "Updates a conference's properties, merged over the current ones (`conference.update`)."
  @spec update_conference(node(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def update_conference(node, uid, attrs) do
    module_command(node, "mcu", "conference.update", Map.put(attrs, "uid", uid))
  end

  @doc """
  Destroys a conference (`kelictl mcu conference.delete`). `admin` identifies who
  requested it, traced in kelixip's own logs. `force` disconnects the
  participants first; without it, a non-empty conference errors `:not_empty`.
  """
  @spec delete_conference(node(), String.t(), String.t(), boolean()) ::
          {:ok, term()} | {:error, :not_found | :not_empty | term()}
  def delete_conference(node, uid, admin, force \\ false) do
    module_command(node, "mcu", "conference.delete", %{
      "uid" => uid,
      "force" => force,
      "admin" => admin
    })
  end

  @doc "Starts recording a conference's mix (`kelictl mcu recording.start`)."
  @spec start_recording(node(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found | :already_recording | term()}
  def start_recording(node, uid, file \\ nil) do
    module_command(node, "mcu", "recording.start", %{"uid" => uid, "file" => file})
  end

  @doc "Stops recording a conference's mix (`kelictl mcu recording.stop`)."
  @spec stop_recording(node(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_recording | term()}
  def stop_recording(node, uid) do
    module_command(node, "mcu", "recording.stop", %{"uid" => uid})
  end
end
