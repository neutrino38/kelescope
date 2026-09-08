defmodule KelescopeWeb.Domaines.Gettext do
  @moduledoc """
  Backend Gettext de cette partie : ses traductions sont livrées dans son propre
  paquet, sans passer par le socle.
  """
  use Gettext.Backend, otp_app: :kelescope_domaines
end
