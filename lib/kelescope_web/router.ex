defmodule KelescopeWeb.Router do
  use KelescopeWeb, :router

  @locales ~w(fr en)

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KelescopeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  defp put_locale(conn, _opts) do
    locale = Plug.Conn.get_session(conn, :locale) |> normalize_locale()
    Gettext.put_locale(KelescopeWeb.Gettext, locale)
    Plug.Conn.assign(conn, :locale, locale)
  end

  defp normalize_locale(locale) when locale in @locales, do: locale
  defp normalize_locale(_locale), do: "fr"

  scope "/", KelescopeWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :update

    live_session :default, on_mount: KelescopeWeb.LocaleHook do
      live "/", ScenarioMonitorLive
      live "/domains", DomainListLive
      live "/domains/:name", DomainShowLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", KelescopeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:kelescope, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KelescopeWeb.Telemetry
    end
  end
end
