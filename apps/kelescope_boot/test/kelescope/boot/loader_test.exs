defmodule Kelescope.Boot.LoaderTest do
  use ExUnit.Case, async: false

  alias Kelescope.Boot.Loader

  @app :fake_plugin
  @module FakePlugin
  @module_ajoute FakePluginAjoute

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "kelescope_loader_test_#{System.unique_integer([:positive])}")

    ebin = Path.join([tmp, "#{@app}-1.0.0", "ebin"])
    File.mkdir_p!(ebin)
    System.put_env("KELESCOPE_PLUGINS_DIR", tmp)

    on_exit(fn ->
      Application.stop(@app)
      Application.unload(@app)

      for module <- [@module, @module_ajoute] do
        :code.purge(module)
        :code.delete(module)
      end

      :code.del_path(to_charlist(ebin))
      System.delete_env("KELESCOPE_PLUGINS_DIR")
      File.rm_rf!(tmp)
    end)

    {:ok, ebin: ebin}
  end

  describe "load_all/0" do
    test "monte l'application, charge ses modules et la démarre", %{ebin: ebin} do
      ecrire_module!(ebin, @module)
      ecrire_app!(ebin, [@module])

      assert Loader.load_all() == [@app]
      assert to_charlist(ebin) in :code.get_path()
      assert apply(@module, :hello, []) == :version_1
      assert @app in Enum.map(Application.started_applications(), &elem(&1, 0))
    end

    test "conserve la configuration posée avant le chargement", %{ebin: ebin} do
      ecrire_module!(ebin, @module)
      ecrire_app!(ebin, [@module])
      Application.put_env(@app, :pose_par_runtime_exs, :valeur)

      Loader.load_all()

      assert Application.get_env(@app, :pose_par_runtime_exs) == :valeur
      assert :persistent_term.get({Loader, @app, :overrides}) == [pose_par_runtime_exs: :valeur]
    end

    test "lève en nommant l'application et le module illisible", %{ebin: ebin} do
      ecrire_module!(ebin, @module)
      ecrire_app!(ebin, [@module, ManquantAuDisque])

      message = assert_raise(RuntimeError, fn -> Loader.load_all() end).message

      assert message =~ "fake_plugin"
      assert message =~ "ManquantAuDisque"
    end

    test "ne fait rien quand le répertoire des plugins est vide" do
      assert Loader.load_all() == []
    end
  end

  describe "reload/1" do
    setup %{ebin: ebin} do
      ecrire_module!(ebin, @module)
      ecrire_app!(ebin, [@module])
      Application.put_env(@app, :pose_par_runtime_exs, :valeur)
      Loader.load_all()
      :ok
    end

    test "prend en compte le nouveau code", %{ebin: ebin} do
      ecrire_module!(ebin, @module, ":version_2")

      assert {:ok, %{retires: []}} = Loader.reload(@app)
      assert apply(@module, :hello, []) == :version_2
    end

    test "charge un module ajouté", %{ebin: ebin} do
      ecrire_module!(ebin, @module_ajoute)
      ecrire_app!(ebin, [@module, @module_ajoute])

      assert {:ok, %{charges: charges}} = Loader.reload(@app)
      assert @module_ajoute in charges
      assert apply(@module_ajoute, :hello, []) == :version_1
    end

    test "purge un module supprimé", %{ebin: ebin} do
      ecrire_module!(ebin, @module_ajoute)
      ecrire_app!(ebin, [@module, @module_ajoute])
      Loader.reload(@app)

      File.rm!(Path.join(ebin, "#{@module_ajoute}.beam"))
      ecrire_app!(ebin, [@module])

      assert {:ok, %{retires: [@module_ajoute]}} = Loader.reload(@app)
      assert :code.which(@module_ajoute) == :non_existing
    end

    test "restaure la configuration que Application.unload/1 efface" do
      Loader.reload(@app)

      assert Application.get_env(@app, :pose_par_runtime_exs) == :valeur
    end

    test "redémarre l'application" do
      Loader.reload(@app)

      assert @app in Enum.map(Application.started_applications(), &elem(&1, 0))
    end

    test "lève sur une application qui n'est pas chargée" do
      message = assert_raise(RuntimeError, fn -> Loader.reload(:jamais_chargee) end).message

      assert message =~ "jamais_chargee"
    end
  end

  describe "versions/0" do
    test "rapporte l'ABI et la version produit de chaque application", %{ebin: ebin} do
      ecrire_module!(ebin, @module)
      ecrire_app!(ebin, [@module])
      Loader.load_all()

      versions = Loader.versions()

      assert versions[@app] == %{abi: "1.0.0", build: nil}
      assert versions[:kelescope_boot].abi != ""
    end
  end

  defp ecrire_module!(ebin, nom, retour \\ ":version_1") do
    :code.purge(nom)
    :code.delete(nom)
    :code.purge(nom)

    [{module, binary}] =
      Code.compile_string("defmodule #{nom} do def hello, do: #{retour} end")

    File.write!(Path.join(ebin, Atom.to_string(module) <> ".beam"), binary)

    # Sans cette purge, le module reste charge en memoire depuis la compilation
    # et le test ne prouverait pas que le chargeur le lit sur le disque.
    :code.purge(module)
    :code.delete(module)
  end

  defp ecrire_app!(ebin, modules) do
    spec =
      {:application, @app,
       [
         {:description, ~c"fake"},
         {:vsn, ~c"1.0.0"},
         {:modules, modules},
         {:registered, []},
         {:applications, [:kernel, :stdlib, :elixir]}
       ]}

    File.write!(Path.join(ebin, "#{@app}.app"), :io_lib.format(~c"~p.~n", [spec]))
  end
end
