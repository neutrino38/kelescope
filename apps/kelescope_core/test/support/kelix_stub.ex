defmodule Kelescope.KelixStub do
  @moduledoc """
  Hands the globally named `Kelix.Control` double back to the application
  supervisor, after a test took it over.
  """

  @doc """
  Waits for the name to be free, then restarts the supervised double.

  A test's own double dies with the test process, but exit signals are
  asynchronous. Restarting too early fails on the name still taken, and the
  run carries on with no double at all: every later test that talks to kelixip
  then fails, in another file and often in another application.
  """
  def restore!(tries \\ 200)

  def restore!(0), do: raise("Kelix.Control never released its registered name")

  def restore!(tries) do
    if Process.whereis(Kelix.Control) do
      Process.sleep(5)
      restore!(tries - 1)
    else
      case Supervisor.restart_child(Kelescope.Supervisor, Kelix.Control) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        other -> raise "could not restart Kelix.Control: #{inspect(other)}"
      end
    end
  end
end
