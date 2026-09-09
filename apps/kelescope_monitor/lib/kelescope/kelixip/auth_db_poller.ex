defmodule Kelescope.Kelixip.AuthDbPoller do
  @moduledoc """
  Polls `Kelix.Control.module_command/3` (`"auth_db"`, `"show"`) on the
  monitored kelixip node and republishes the result via `Phoenix.PubSub` on
  `"kelixip:auth_db"`.

  `Kelix.Control.status/0` says nothing about this module's database
  connection. The state lives behind the module's own control command, the one
  `kelictl auth_db show` reaches.

  Unlike `StatusPoller`, this one publishes its
  failures too. A connection state that kept showing the last success after
  the module stopped answering would be a lie, and this page exists to tell
  the truth about a connection.
  """
  use GenServer
  require Logger

  @auth_db_topic "kelixip:auth_db"
  @poll_interval 20_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Last poll result, or `nil` before the first poll completes. `{:ok, details}`
  carries whatever the module reported, key names included.
  """
  @spec snapshot(GenServer.server()) :: {:ok, map()} | {:error, term()} | nil
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec topic() :: String.t()
  def topic, do: @auth_db_topic

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    cookie = Keyword.get(opts, :cookie)
    if cookie, do: Node.set_cookie(node, String.to_atom(cookie))
    send(self(), :poll)

    {:ok,
     %{
       node: node,
       interval: Keyword.get(opts, :poll_interval, @poll_interval),
       topic: Keyword.get(opts, :auth_db_topic, @auth_db_topic),
       result: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.result, state}

  @impl true
  def handle_info(:poll, state) do
    result = poll(state.node)

    if match?({:error, reason} when reason != :unknown_module, result) do
      {:error, reason} = result
      Logger.warning("kelixip auth_db poll to #{state.node}: #{inspect(reason)}")
    end

    Phoenix.PubSub.broadcast(Kelescope.PubSub, state.topic, {:kelixip_auth_db, result})
    Process.send_after(self(), :poll, state.interval)
    {:noreply, %{state | result: result}}
  end

  defp poll(node) do
    case Kelescope.Kelixip.Control.module_command(node, "auth_db", "show", %{}) do
      {:ok, details} when is_map(details) -> {:ok, details}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end
end
