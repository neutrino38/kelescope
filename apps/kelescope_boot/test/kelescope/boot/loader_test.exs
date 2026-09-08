defmodule Kelescope.Boot.LoaderTest do
  use ExUnit.Case, async: false

  alias Kelescope.Boot.Loader

  @app :fake_plugin
  @module FakePlugin

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "kelescope_loader_test_#{System.unique_integer([:positive])}")

    ebin = Path.join([tmp, "#{@app}-1.0.0", "ebin"])
    File.mkdir_p!(ebin)
    System.put_env("KELESCOPE_PLUGINS_DIR", tmp)

    on_exit(fn ->
      Application.stop(@app)
      Application.unload(@app)
      :code.purge(@module)
      :code.delete(@module)
      :code.del_path(to_charlist(ebin))
      System.delete_env("KELESCOPE_PLUGINS_DIR")
      File.rm_rf!(tmp)
    end)

    {:ok, ebin: ebin}
  end

  test "monte l'application, charge ses modules et la démarre", %{ebin: ebin} do
    write_module!(ebin)
    write_app!(ebin, [@module])

    assert Loader.load_all() == [@app]
    assert to_charlist(ebin) in :code.get_path()
    assert apply(@module, :hello, []) == :depuis_le_plugin
    assert @app in Enum.map(Application.started_applications(), &elem(&1, 0))
  end

  test "conserve la configuration posée avant le chargement", %{ebin: ebin} do
    write_module!(ebin)
    write_app!(ebin, [@module])
    Application.put_env(@app, :pose_par_runtime_exs, :valeur)

    Loader.load_all()

    assert Application.get_env(@app, :pose_par_runtime_exs) == :valeur
    assert :persistent_term.get({Loader, @app, :overrides}) == [pose_par_runtime_exs: :valeur]
  end

  test "lève en nommant l'application et le module illisible", %{ebin: ebin} do
    write_module!(ebin)
    write_app!(ebin, [@module, ManquantAuDisque])

    message = assert_raise(RuntimeError, fn -> Loader.load_all() end).message

    assert message =~ "fake_plugin"
    assert message =~ "ManquantAuDisque"
  end

  test "ne fait rien quand le répertoire des plugins est vide" do
    assert Loader.load_all() == []
  end

  defp write_module!(ebin) do
    [{module, binary}] =
      Code.compile_string("defmodule #{@module} do def hello, do: :depuis_le_plugin end")

    File.write!(Path.join(ebin, Atom.to_string(module) <> ".beam"), binary)

    # Sans cette purge, le module reste charge en memoire depuis la compilation
    # et le test ne prouverait pas que le chargeur le lit sur le disque.
    :code.purge(module)
    :code.delete(module)
  end

  defp write_app!(ebin, modules) do
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
