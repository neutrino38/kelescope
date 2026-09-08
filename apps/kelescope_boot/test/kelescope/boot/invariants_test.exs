defmodule Kelescope.Boot.InvariantsTest do
  use ExUnit.Case, async: true

  @socle :kelescope_core

  test "aucune partie hors du socle n'implémente de protocole" do
    for partie <- parties(), partie != @socle, module <- modules(partie) do
      Code.ensure_loaded(module)

      refute function_exported?(module, :__impl__, 1),
             "#{module} implémente un protocole depuis #{partie}. " <>
               "La consolidation est globale et vit dans le paquet runtime : " <>
               "une implémentation hors du socle n'y figure pas."
    end
  end

  defp parties do
    "../*/mix.exs"
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename() |> String.to_atom()))
    |> List.delete(:kelescope_boot)
  end

  defp modules(app) do
    Application.load(app)
    Application.spec(app, :modules) || []
  end
end
