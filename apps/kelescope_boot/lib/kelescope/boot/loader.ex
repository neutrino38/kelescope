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

  @doc """
  Recharge une application déjà montée, sans redémarrer le nœud.

  Les processus qui exécutent encore l'ancien code d'un module rechargé sont
  tués : une vue LiveView ouverte sur une page rechargée se remonte côté client.
  """
  def reload(app) do
    anciens = Application.spec(app, :modules) || nil

    if is_nil(anciens) do
      raise "plugin #{app} : non chargé, un rechargement à chaud n'est pas possible"
    end

    arreter(app)
    :ok = Application.unload(app)
    :ok = Application.load(app)
    restaurer_surcharges(app)

    nouveaux = Application.spec(app, :modules) || []
    retires = anciens -- nouveaux

    Enum.each(retires, fn module ->
      :code.purge(module)
      :code.delete(module)
    end)

    Enum.each(nouveaux, fn module ->
      :code.purge(module)

      case :code.load_file(module) do
        {:module, ^module} ->
          :ok

        {:error, reason} ->
          raise "plugin #{app} : module #{module} illisible (#{inspect(reason)})"
      end
    end)

    {:ok, _demarrees} = Application.ensure_all_started(app)

    {:ok, %{application: app, retires: retires, charges: nouveaux}}
  end

  @doc """
  Version d'ABI et version produit de chaque application chargée.

  Le numéro de version du RPM ne décrit plus ce qui tourne : une machine peut
  porter un socle et une partie construits séparément.
  """
  def versions do
    for app <- [:kelescope_boot | applications_installees()], into: %{} do
      {app,
       %{
         abi: to_string(Application.spec(app, :vsn) || ~c""),
         build: Application.get_env(app, :build)
       }}
    end
  end

  defp applications_installees do
    plugins_dir()
    |> Path.join("*/ebin/*.app")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> Path.basename(".app") |> String.to_atom()))
  end

  defp arreter(app) do
    case Application.stop(app) do
      :ok -> :ok
      {:error, {:not_started, ^app}} -> :ok
      {:error, reason} -> raise "plugin #{app} : arrêt impossible (#{inspect(reason)})"
    end
  end

  defp restaurer_surcharges(app) do
    for {cle, valeur} <- :persistent_term.get({__MODULE__, app, :overrides}, []) do
      Application.put_env(app, cle, valeur)
    end
  end
end
