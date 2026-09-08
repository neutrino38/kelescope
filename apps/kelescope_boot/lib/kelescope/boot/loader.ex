defmodule Kelescope.Boot.Loader do
  @moduledoc """
  Charge les applications kelescope installées hors de la release.

  Voir `docs/conception/decoupage-rpm/SPEC.md`.
  """

  def plugins_dir do
    System.get_env("KELESCOPE_PLUGINS_DIR") ||
      Path.join(System.get_env("RELEASE_ROOT") || File.cwd!(), "plugins")
  end

  @doc """
  Monte toutes les applications présentes dans le répertoire des plugins et
  retourne leurs noms. Lève sur la première application illisible.
  """
  def load_all do
    apps =
      plugins_dir()
      |> Path.join("*/ebin")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(&add_code_path/1)

    Enum.each(apps, &load/1)
    Enum.each(apps, &load_modules/1)
    Enum.each(apps, &start/1)

    apps
  end

  defp add_code_path(ebin) do
    true = :code.add_pathz(to_charlist(ebin))

    ebin
    |> Path.join("*.app")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".app") |> String.to_atom()))
  end

  defp load(app) do
    :persistent_term.put({__MODULE__, app, :overrides}, Application.get_all_env(app))

    case Application.load(app) do
      :ok -> :ok
      {:error, reason} -> raise "plugin #{app} : chargement impossible (#{inspect(reason)})"
    end
  end

  defp load_modules(app) do
    for module <- Application.spec(app, :modules) || [] do
      case :code.load_file(module) do
        {:module, ^module} ->
          :ok

        {:error, reason} ->
          raise "plugin #{app} : module #{module} illisible (#{inspect(reason)})"
      end
    end
  end

  defp start(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, reason} -> raise "plugin #{app} : démarrage impossible (#{inspect(reason)})"
    end
  end
end
