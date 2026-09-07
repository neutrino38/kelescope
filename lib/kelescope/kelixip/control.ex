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
end
