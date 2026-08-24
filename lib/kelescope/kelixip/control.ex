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
end
