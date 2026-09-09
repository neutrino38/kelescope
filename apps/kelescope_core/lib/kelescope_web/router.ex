defmodule KelescopeWeb.Router do
  use KelescopeWeb, :router

  # Ces vues sont livrees par d'autres paquets : elles n'existent pas a la
  # compilation du socle, seulement a l'execution.
  @compile {:no_warn_undefined,
            [
              KelescopeWeb.ScenarioMonitorLive,
              KelescopeWeb.DomainListLive,
              KelescopeWeb.McuLive,
              KelescopeWeb.AccountLive,
              KelescopeWeb.AdminsLive
            ]}

  alias KelescopeWeb.Locale

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KelescopeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
    plug KelescopeWeb.Plugs.Auth, require: :none
  end

  pipeline :authenticated do
    plug KelescopeWeb.Plugs.Auth, require: :authenticated
  end

  pipeline :global_admin do
    plug KelescopeWeb.Plugs.Auth, require: :manage_accounts
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The chosen locale is written back into the session, because a LiveView
  # mounting over the websocket sees the session and never the headers.
  defp put_locale(conn, _opts) do
    stored = Plug.Conn.get_session(conn, :locale)
    locale = if Locale.supported?(stored), do: stored, else: negotiate_locale(conn)

    Gettext.put_locale(locale)

    conn
    |> remember_locale(locale, stored)
    |> Plug.Conn.assign(:locale, locale)
  end

  defp remember_locale(conn, locale, locale), do: conn
  defp remember_locale(conn, locale, _stored), do: Plug.Conn.put_session(conn, :locale, locale)

  defp negotiate_locale(conn) do
    conn
    |> Plug.Conn.get_req_header("accept-language")
    |> List.first()
    |> Locale.from_accept_language()
  end

  scope "/", KelescopeWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :update
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete

    live_session :public,
      on_mount: [{KelescopeWeb.AuthHook, :none}, KelescopeWeb.LocaleHook],
      session: {KelescopeWeb.AuthHook, :peer_session, []} do
      live "/enroll", EnrollLive
      live "/login", LoginLive
    end
  end

  scope "/", KelescopeWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [{KelescopeWeb.AuthHook, :authenticated}, KelescopeWeb.LocaleHook],
      session: {KelescopeWeb.AuthHook, :peer_session, []} do
      live "/", ScenarioMonitorLive
      live "/domains", DomainListLive
      live "/mcu", McuLive
      live "/account", AccountLive
    end
  end

  scope "/", KelescopeWeb do
    pipe_through [:browser, :global_admin]

    live_session :global_admin,
      on_mount: [{KelescopeWeb.AuthHook, :manage_accounts}, KelescopeWeb.LocaleHook],
      session: {KelescopeWeb.AuthHook, :peer_session, []} do
      live "/admins", AdminsLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", KelescopeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:kelescope_core, :dev_routes) do
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
