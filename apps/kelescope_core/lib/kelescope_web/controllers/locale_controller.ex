defmodule KelescopeWeb.LocaleController do
  use KelescopeWeb, :controller

  @locales KelescopeWeb.Locale.locales()

  def update(conn, %{"locale" => locale}) when locale in @locales do
    conn
    |> put_session(:locale, locale)
    |> redirect(to: redirect_target(conn))
  end

  defp redirect_target(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{path: path} when is_binary(path) <- URI.parse(referer) do
      path
    else
      _ -> ~p"/"
    end
  end
end
