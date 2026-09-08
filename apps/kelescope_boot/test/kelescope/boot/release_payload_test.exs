defmodule Kelescope.Boot.ReleasePayloadTest do
  use ExUnit.Case, async: true

  test "la release embarque toutes les applications dont les parties dépendent" do
    embarquees = fermeture(:kelescope_boot)
    parties = parties()

    for partie <- parties,
        dependance <- dependances(partie),
        dependance not in parties do
      assert dependance in embarquees,
             "#{partie} dépend de #{dependance}, absente de la charge utile de kelescope_boot"
    end
  end

  defp parties do
    "../*/mix.exs"
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename() |> String.to_atom()))
    |> List.delete(:kelescope_boot)
  end

  defp dependances(app) do
    Application.load(app)
    Application.spec(app, :applications) || []
  end

  defp fermeture(app, vues \\ MapSet.new()) do
    if MapSet.member?(vues, app) do
      vues
    else
      Enum.reduce(dependances(app), MapSet.put(vues, app), &fermeture/2)
    end
  end
end
