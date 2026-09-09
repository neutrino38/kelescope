defmodule Kelescope.AuthCase do
  @moduledoc """
  Gives each test its own account store, in its own directory, so tests that
  touch the global-administrator invariants do not see each other's accounts.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Kelescope.AuthCase
    end
  end

  setup do
    %{store: start_store()}
  end

  @doc """
  Starts an isolated store and returns its name, to be passed as `store:`.
  """
  def start_store(dir \\ nil) do
    suffix = System.unique_integer([:positive])
    dir = dir || auth_dir(suffix)
    name = :"kelescope_auth_store_#{suffix}"

    ExUnit.Callbacks.start_supervised!({Kelescope.Auth.Store, name: name, dir: dir})
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)

    name
  end

  def auth_dir(suffix \\ System.unique_integer([:positive])) do
    Path.join(System.tmp_dir!(), "kelescope-auth-#{suffix}")
  end
end
