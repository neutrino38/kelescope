defmodule KelescopeWeb.LocaleHook do
  @moduledoc """
  Gettext locale is stored per-process: the LiveView process is not the one
  the router's :put_locale plug ran in, so it needs to re-apply it from the
  session on every mount.

  The locale is set globally rather than per backend: each part carries its own
  Gettext backend, and they all read the global one.
  """
  import Phoenix.Component, only: [assign: 3]

  @locales ~w(fr en)

  def on_mount(:default, _params, session, socket) do
    locale = normalize_locale(Map.get(session, "locale"))
    Gettext.put_locale(locale)
    {:cont, assign(socket, :locale, locale)}
  end

  defp normalize_locale(locale) when locale in @locales, do: locale
  defp normalize_locale(_locale), do: "fr"
end
