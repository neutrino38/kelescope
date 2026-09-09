defmodule Kelescope.Auth.Scope do
  @moduledoc """
  What the connected administrator is allowed to see and to do.

  A level says read (`:monitor`) or act (`:admin`). A reach says the whole
  instance (`:all`) or a list of kelixip domains. Every rendering and every
  event handler asks this module, never the browser.
  """

  defstruct [:admin, :certificate, dev?: false]

  @type t :: %__MODULE__{
          admin: %{id: String.t(), level: :monitor | :admin, domains: :all | [String.t()]},
          certificate: map() | nil,
          dev?: boolean()
        }

  @doc """
  Builds the scope of an account, optionally bound to the client certificate
  that opened the session.
  """
  def new(account, certificate \\ nil) do
    %__MODULE__{
      admin: %{id: account.id, level: account.level, domains: account.scope},
      certificate: certificate
    }
  end

  @doc """
  Synthetic global administrator of the dev mode.
  """
  def dev do
    %__MODULE__{
      admin: %{id: "dev", level: :admin, domains: :all},
      certificate: nil,
      dev?: true
    }
  end

  @doc """
  True when the scope covers the whole instance, whatever its level.
  """
  def global?(%__MODULE__{admin: %{domains: :all}}), do: true
  def global?(%__MODULE__{}), do: false

  @doc """
  True when the domain belongs to the scope. A `nil` domain belongs to no
  limited scope: an object with no domain is instance-wide.
  """
  def sees_domain?(%__MODULE__{admin: %{domains: :all}}, _domain), do: true
  def sees_domain?(%__MODULE__{}, nil), do: false
  def sees_domain?(%__MODULE__{admin: %{domains: domains}}, domain), do: domain in domains

  @doc """
  True when the scope may run `action` on `domain`. `:manage_accounts` is the
  only action reserved to a global administrator.
  """
  def can?(scope, action, domain \\ nil)

  def can?(%__MODULE__{admin: %{level: :admin, domains: :all}}, :manage_accounts, _domain),
    do: true

  def can?(%__MODULE__{}, :manage_accounts, _domain), do: false

  def can?(%__MODULE__{admin: %{level: :admin}} = scope, _action, domain),
    do: sees_domain?(scope, domain)

  def can?(%__MODULE__{}, _action, _domain), do: false

  @doc """
  Domains of the scope, kept to those kelixip actually knows about.
  """
  def visible_domains(%__MODULE__{admin: %{domains: :all}}, known), do: known

  def visible_domains(%__MODULE__{admin: %{domains: domains}}, known),
    do: Enum.filter(known, &(&1 in domains))

  def id(%__MODULE__{admin: %{id: id}}), do: id
end
