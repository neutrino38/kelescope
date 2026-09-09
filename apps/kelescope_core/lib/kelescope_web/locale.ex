defmodule KelescopeWeb.Locale do
  @moduledoc """
  The locales kelescope serves, and how a request gets one.

  The router, `KelescopeWeb.LocaleController` and `KelescopeWeb.LocaleHook` all
  read this module, so the list of locales lives in one place.

  A session that carries no choice yet is negotiated from `accept-language`:
  a browser set to English lands on English without touching the switch. The
  router then writes that locale into the session, which is what lets a
  LiveView mount over the websocket find it.
  """

  @locales ~w(fr en)
  @default "fr"

  def locales, do: @locales

  def default, do: @default

  def supported?(locale), do: locale in @locales

  @doc """
  Keeps a locale kelescope serves, falls back to the default otherwise.
  """
  def normalize(locale) when locale in @locales, do: locale
  def normalize(_locale), do: @default

  @doc """
  Best served locale of an `accept-language` header value, by decreasing
  quality. The match is on the language subtag alone: `en-GB` selects `en`.
  A tag the header refuses with `q=0` is never selected.
  """
  def from_accept_language(nil), do: @default

  def from_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&tag_and_quality/1)
    |> Enum.reject(fn {_tag, quality} -> quality == 0.0 end)
    |> Enum.sort_by(fn {_tag, quality} -> quality end, :desc)
    |> Enum.find_value(@default, fn {tag, _quality} -> supported?(tag) && tag end)
  end

  defp tag_and_quality(entry) do
    [tag | params] = String.split(entry, ";")
    {subtag(tag), quality(params)}
  end

  defp subtag(tag) do
    tag |> String.trim() |> String.downcase() |> String.split("-") |> hd()
  end

  defp quality(params) do
    Enum.find_value(params, 1.0, fn param ->
      with "q=" <> value <- String.trim(param),
           {quality, ""} <- Float.parse(value) do
        quality
      else
        _ -> nil
      end
    end)
  end
end
