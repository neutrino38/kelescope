defmodule KelescopeWeb.AdminsLive do
  @moduledoc """
  Account management, reserved to a global administrator.

  Creating an account produces an invitation code, shown once. The same button
  on an existing account resets it, which is what unblocks someone who lost
  their passkey or their workstation.
  """
  use KelescopeWeb, {:live_view, KelescopeWeb.Admins.Gettext}

  alias Kelescope.Auth
  alias Kelescope.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Comptes"))
     |> assign(:invitation, nil)
     |> assign(:error, nil)
     |> assign(:editing, nil)
     |> assign(:pending_delete, nil)
     |> assign(:current_id, Scope.id(socket.assigns.current_scope))
     |> assign_served_domains()
     |> load_accounts()}
  end

  defp assign_served_domains(socket) do
    {status, domains} = Kelescope.Kelixip.DomainsLink.snapshot()

    socket
    |> assign(:link_connected?, status == :connected)
    |> assign(:served_domains, domains |> Enum.map(& &1.name) |> Enum.sort())
  end

  defp load_accounts(socket), do: assign(socket, :accounts, Auth.list_accounts())

  @impl true
  def handle_event("create", %{"admin_id" => id, "level" => level} = params, socket) do
    attrs = %{id: String.trim(id), level: level, scope: parse_scope(params)}

    case Auth.create_account(attrs) do
      {:ok, {account, code}} ->
        {:noreply,
         socket
         |> assign(:invitation, {account.id, code})
         |> assign(:error, nil)
         |> load_accounts()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("invite", %{"id" => id}, socket) do
    case Auth.invite(id) do
      {:ok, code} ->
        {:noreply, socket |> assign(:invitation, {id, code}) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("dismiss_invitation", _params, socket) do
    {:noreply, assign(socket, :invitation, nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing, id)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("update_role", %{"admin_id" => id, "level" => level} = params, socket) do
    if id == socket.assigns.current_id do
      {:noreply, assign(socket, :error, gettext("Vous ne pouvez pas changer votre propre rôle."))}
    else
      case Auth.update_role(id, %{level: level, scope: parse_scope(params)}) do
        {:ok, _account} ->
          {:noreply, socket |> assign(:editing, nil) |> assign(:error, nil) |> load_accounts()}

        {:error, reason} ->
          {:noreply, assign(socket, :error, error_message(reason))}
      end
    end
  end

  def handle_event("toggle_enabled", %{"id" => id, "enabled" => enabled}, socket) do
    if id == socket.assigns.current_id do
      {:noreply,
       assign(socket, :error, gettext("Vous ne pouvez pas désactiver votre propre compte."))}
    else
      case Auth.set_enabled(id, enabled == "true") do
        {:ok, _account} -> {:noreply, socket |> assign(:error, nil) |> load_accounts()}
        {:error, reason} -> {:noreply, assign(socket, :error, error_message(reason))}
      end
    end
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :pending_delete, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("delete", %{"admin_id" => id}, socket) do
    socket =
      if id == socket.assigns.current_id do
        assign(socket, :error, gettext("Vous ne pouvez pas supprimer votre propre compte."))
      else
        case Auth.delete_account(id) do
          {:ok, _id} -> assign(socket, :error, nil)
          {:error, reason} -> assign(socket, :error, error_message(reason))
        end
      end

    {:noreply, socket |> assign(:pending_delete, nil) |> load_accounts()}
  end

  def handle_event("revoke_passkey", %{"id" => id, "credential" => credential}, socket) do
    credential_id = Base.url_decode64!(credential, padding: false)

    case Auth.revoke_passkey(id, credential_id) do
      {:ok, _account} -> {:noreply, socket |> assign(:error, nil) |> load_accounts()}
      {:error, reason} -> {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("revoke_certificate", %{"id" => id, "fingerprint" => fingerprint}, socket) do
    case Auth.revoke_certificate(id, fingerprint) do
      {:ok, _account} -> {:noreply, socket |> assign(:error, nil) |> load_accounts()}
      {:error, reason} -> {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  # The checkboxes win when the domain list is known; the text field is what
  # remains when kelixip has never told us which domains it serves.
  defp parse_scope(%{"reach" => "all"}), do: :all
  defp parse_scope(%{"domains" => domains}) when is_list(domains), do: domains
  defp parse_scope(%{"scope" => "all"}), do: :all

  defp parse_scope(%{"scope" => text}) when is_binary(text),
    do: String.split(text, [",", " ", "\n"], trim: true)

  defp parse_scope(_params), do: []

  defp error_message(:already_taken), do: gettext("Cet identifiant existe déjà.")
  defp error_message(:invalid_id), do: gettext("Identifiant invalide : a-z, 0-9, . _ -, 2 à 32.")
  defp error_message(:invalid_scope), do: gettext("Portée invalide.")
  defp error_message(:not_found), do: gettext("Compte introuvable.")
  defp error_message(:last_passkey), do: gettext("C'est la dernière passkey de ce compte.")
  defp error_message(:last_certificate), do: gettext("C'est le dernier poste de ce compte.")

  defp error_message(:last_global_admin),
    do: gettext("Il doit rester un administrateur général actif.")

  defp error_message(_reason), do: gettext("Action impossible.")

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:admins} locale={@locale} scope={@current_scope} />
    <Layouts.flash_group flash={@flash} />

    <div class="mx-auto max-w-5xl space-y-6 p-6">
      <h1 class="text-lg font-semibold">{gettext("Comptes administrateurs")}</h1>

      <div :if={@error} class="rounded bg-error/20 p-3 text-sm">{@error}</div>

      <div :if={@invitation} class="rounded bg-success/20 p-3 text-sm">
        <p>
          {gettext("Code d'invitation de %{id}, affiché une seule fois :", id: elem(@invitation, 0))}
          <code class="select-all rounded bg-base-300 px-2 py-1 font-mono">
            {elem(@invitation, 1)}
          </code>
        </p>
        <p class="mt-1 text-xs">
          {gettext("Valable %{hours} h. À transmettre par le canal de votre choix.",
            hours: Kelescope.Auth.invite_hours()
          )}
        </p>
        <button type="button" phx-click="dismiss_invitation" class="btn btn-xs mt-2">
          {gettext("Masquer")}
        </button>
      </div>

      <table class="w-full text-left text-sm">
        <thead>
          <tr>
            <th class="border-b p-2">{gettext("Identifiant")}</th>
            <th class="border-b p-2">{gettext("Rôle")}</th>
            <th class="border-b p-2">{gettext("État")}</th>
            <th class="border-b p-2">{gettext("Passkeys")}</th>
            <th class="border-b p-2">{gettext("Postes")}</th>
            <th class="border-b p-2">{gettext("Dernière connexion")}</th>
            <th class="border-b p-2">{gettext("actions")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={account <- @accounts} id={"account-#{account.id}"}>
            <td class="border-b p-2 font-mono">{account.id}</td>
            <td class="border-b p-2">{level_label(account.level)} / {scope_label(account.scope)}</td>
            <td class="border-b p-2">
              {if account.enabled, do: gettext("actif"), else: gettext("désactivé")}
            </td>
            <td class="border-b p-2">{length(account.passkeys)}</td>
            <td class="border-b p-2">{length(Kelescope.Auth.active_certificates(account))}</td>
            <td class="border-b p-2">{date(account.last_login_at)}</td>
            <td class="border-b space-x-1 p-2">
              <button
                :if={account.id != @current_id}
                type="button"
                phx-click="edit"
                phx-value-id={account.id}
                class="btn btn-xs"
              >
                {gettext("Rôle")}
              </button>
              <button
                type="button"
                phx-click="invite"
                phx-value-id={account.id}
                class="btn btn-xs"
              >
                {gettext("Réinitialiser")}
              </button>
              <button
                :if={account.id != @current_id}
                type="button"
                phx-click="toggle_enabled"
                phx-value-id={account.id}
                phx-value-enabled={to_string(not account.enabled)}
                class="btn btn-xs"
              >
                {if account.enabled, do: gettext("Désactiver"), else: gettext("Réactiver")}
              </button>
              <button
                :if={account.id != @current_id}
                type="button"
                phx-click="ask_delete"
                phx-value-id={account.id}
                class="btn btn-xs btn-error"
              >
                {gettext("Supprimer")}
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <section :if={@editing} class="rounded bg-base-200 p-4">
        <h2 class="mb-2 text-sm font-semibold">{gettext("Rôle de %{id}", id: @editing)}</h2>
        <form phx-submit="update_role" class="flex flex-wrap items-end gap-2 text-sm">
          <input type="hidden" name="admin_id" value={@editing} />
          <.role_fields
            account={Enum.find(@accounts, &(&1.id == @editing))}
            prefix="edit"
            served={@served_domains}
            link_connected?={@link_connected?}
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Enregistrer")}</button>
          <button type="button" phx-click="cancel_edit" class="btn btn-sm">
            {gettext("Annuler")}
          </button>
        </form>
      </section>

      <section class="rounded bg-base-200 p-4">
        <h2 class="mb-2 text-sm font-semibold">{gettext("Créer un compte")}</h2>
        <form phx-submit="create" class="flex flex-wrap items-end gap-2 text-sm">
          <div>
            <label for="new-id" class="mb-1 block text-xs uppercase">{gettext("Identifiant")}</label>
            <input
              id="new-id"
              name="admin_id"
              required
              class="input input-sm"
              placeholder="prenom.nom"
            />
          </div>
          <.role_fields
            account={nil}
            prefix="new"
            served={@served_domains}
            link_connected?={@link_connected?}
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Créer")}</button>
        </form>
      </section>

      <section :for={account <- @accounts} :if={@editing == account.id} class="space-y-2 text-sm">
        <h2 class="text-sm font-semibold">{gettext("Moyens d'accès de %{id}", id: account.id)}</h2>
        <ul class="space-y-1">
          <li :for={passkey <- account.passkeys} class="flex items-center gap-2">
            <span>{passkey.label} — {date(passkey.created_at)}</span>
            <button
              type="button"
              phx-click="revoke_passkey"
              phx-value-id={account.id}
              phx-value-credential={encode(passkey.credential_id)}
              class="btn btn-xs btn-error"
            >
              {gettext("Révoquer")}
            </button>
          </li>
          <li
            :for={certificate <- Kelescope.Auth.active_certificates(account)}
            class="flex items-center gap-2"
          >
            <span>{certificate.label} — {date(certificate.expires_at)}</span>
            <button
              type="button"
              phx-click="revoke_certificate"
              phx-value-id={account.id}
              phx-value-fingerprint={certificate.fingerprint}
              class="btn btn-xs btn-error"
            >
              {gettext("Révoquer")}
            </button>
          </li>
        </ul>
      </section>

      <.admin_confirm_modal
        :if={@pending_delete}
        id="delete-account-modal"
        title={gettext("Supprimer ce compte")}
        confirm_event="delete"
        cancel_event="cancel_delete"
        confirm_values={%{"admin_id" => @pending_delete}}
        confirm_label={gettext("Supprimer")}
      >
        {gettext("Le compte, ses passkeys et ses postes disparaissent.")}
      </.admin_confirm_modal>
    </div>
    """
  end

  attr :account, :any, default: nil
  attr :prefix, :string, required: true
  attr :served, :list, required: true
  attr :link_connected?, :boolean, required: true

  defp role_fields(assigns) do
    assigns = assign(assigns, :choices, scope_choices(assigns.account, assigns.served))

    ~H"""
    <div>
      <label for={"#{@prefix}-level"} class="mb-1 block text-xs uppercase">
        {gettext("Niveau")}
      </label>
      <select id={"#{@prefix}-level"} name="level" class="select select-sm">
        <option value="monitor" selected={@account && @account.level == :monitor}>
          {gettext("moniteur")}
        </option>
        <option value="admin" selected={@account && @account.level == :admin}>
          {gettext("administrateur")}
        </option>
      </select>
    </div>
    <fieldset class="space-y-1">
      <legend class="mb-1 block text-xs uppercase">{gettext("Portée")}</legend>

      <label class="flex items-center gap-2">
        <input
          type="radio"
          name="reach"
          value="all"
          class="radio radio-sm"
          checked={@account && @account.scope == :all}
        />
        {gettext("Toute l'instance")}
      </label>

      <label class="flex items-center gap-2">
        <input
          type="radio"
          name="reach"
          value="domains"
          class="radio radio-sm"
          checked={@account && is_list(@account.scope)}
        />
        {gettext("Domaines choisis")}
      </label>

      <div :if={@choices != []} class="ml-6 space-y-1">
        <label :for={choice <- @choices} class="flex items-center gap-2">
          <input
            type="checkbox"
            name="domains[]"
            value={choice.name}
            class="checkbox checkbox-sm"
            checked={choice.checked}
          />
          <span class="font-mono text-xs">{choice.name}</span>
          <span :if={not choice.served} class="text-xs text-warning">
            {gettext("non servi")}
          </span>
        </label>
      </div>

      <div :if={@choices == []} class="ml-6">
        <input
          id={"#{@prefix}-scope"}
          name="scope"
          value={@account && scope_value(@account.scope)}
          class="input input-sm"
          placeholder={gettext("domaines séparés par des virgules")}
        />
        <p class="mt-1 text-xs text-warning">
          {gettext("kelixip n'a pas encore donné la liste des domaines : saisissez-les.")}
        </p>
      </div>

      <p :if={not @link_connected? and @choices != []} class="text-xs text-warning">
        {gettext("Le lien kelixip est coupé : cette liste peut être en retard.")}
      </p>
    </fieldset>
    """
  end

  # A domain still in someone's scope but no longer served must stay visible and
  # checked: dropping it silently would change what that account may see.
  defp scope_choices(account, served) do
    chosen =
      case account && account.scope do
        domains when is_list(domains) -> domains
        _other -> []
      end

    (served ++ chosen)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{name: &1, served: &1 in served, checked: &1 in chosen})
  end

  defp scope_value(:all), do: "all"
  defp scope_value(domains), do: Enum.join(domains, ", ")

  defp level_label(:admin), do: gettext("administrateur")
  defp level_label(:monitor), do: gettext("moniteur")

  defp scope_label(:all), do: gettext("tous domaines")
  defp scope_label(domains), do: Enum.join(domains, ", ")

  defp date(nil), do: "—"
  defp date(time), do: Calendar.strftime(time, "%d/%m/%Y %H:%M")

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
end
