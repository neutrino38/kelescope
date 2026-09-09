defmodule KelescopeWeb.AccountLive do
  @moduledoc """
  What an administrator manages on their own: their passkeys and their
  workstations. Both factors are already proven here, so no global
  administrator is needed.
  """
  use KelescopeWeb, {:live_view, KelescopeWeb.Admins.Gettext}

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey
  alias Kelescope.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    if Auth.dev_mode?() do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok,
       socket
       |> assign(:page_title, gettext("Mon compte"))
       |> assign(:challenge, nil)
       |> assign(:passkey_label, nil)
       |> assign(:issued, nil)
       |> assign(:error, nil)
       |> assign(:info, nil)
       |> assign(:pending_passkey, nil)
       |> assign(:pending_certificate, nil)
       |> assign(:current_fingerprint, current_fingerprint(socket))
       |> load_account()}
    end
  end

  defp load_account(socket) do
    {:ok, account} = Auth.fetch_account(Scope.id(socket.assigns.current_scope))
    assign(socket, :account, account)
  end

  @impl true
  def handle_event("add_passkey", %{"label" => label}, socket) do
    {challenge, options} = Passkey.registration_challenge(socket.assigns.account)

    {:noreply,
     socket
     |> assign(:challenge, challenge)
     |> assign(:passkey_label, String.trim(label))
     |> assign(:error, nil)
     |> push_event("passkey:create", options)}
  end

  def handle_event("passkey:result", response, socket) do
    %{account: account, challenge: challenge, passkey_label: label} = socket.assigns

    with {:ok, registered} <- Passkey.verify_registration(response, challenge),
         {:ok, _account} <- Auth.add_passkey(account.id, Map.put(registered, :label, label)) do
      {:noreply, socket |> load_account() |> assign(:info, gettext("Passkey enregistrée."))}
    else
      _error ->
        {:noreply, assign(socket, :error, gettext("La passkey n'a pas pu être enregistrée."))}
    end
  end

  def handle_event("passkey:error", %{"message" => message}, socket) do
    {:noreply, assign(socket, :error, message)}
  end

  def handle_event("add_certificate", %{"label" => label}, socket) do
    case Auth.issue_certificate(socket.assigns.account.id, String.trim(label)) do
      {:ok, issued} ->
        {:noreply,
         socket
         |> load_account()
         |> assign(:issued, Map.delete(issued, :pkcs12))
         |> assign(:error, nil)
         |> push_event("download", %{
           "filename" => "kelescope-#{socket.assigns.account.id}.p12",
           "content_type" => "application/x-pkcs12",
           "data" => Base.encode64(issued.pkcs12)
         })}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Le certificat n'a pas pu être émis."))}
    end
  end

  def handle_event("ask_revoke_passkey", %{"id" => credential_id}, socket) do
    {:noreply, assign(socket, :pending_passkey, credential_id)}
  end

  def handle_event("cancel_revoke_passkey", _params, socket) do
    {:noreply, assign(socket, :pending_passkey, nil)}
  end

  def handle_event("revoke_passkey", %{"credential" => credential_id}, socket) do
    credential_id = Base.url_decode64!(credential_id, padding: false)

    socket =
      case Auth.revoke_passkey(socket.assigns.account.id, credential_id) do
        {:ok, _account} -> assign(socket, error: nil, info: gettext("Passkey révoquée."))
        {:error, reason} -> assign(socket, error: revocation_error(reason), info: nil)
      end

    {:noreply, socket |> assign(:pending_passkey, nil) |> load_account()}
  end

  def handle_event("ask_revoke_certificate", %{"fingerprint" => fingerprint}, socket) do
    {:noreply, assign(socket, :pending_certificate, fingerprint)}
  end

  def handle_event("cancel_revoke_certificate", _params, socket) do
    {:noreply, assign(socket, :pending_certificate, nil)}
  end

  def handle_event("revoke_certificate", %{"fingerprint" => fingerprint}, socket) do
    socket =
      if fingerprint == socket.assigns.current_fingerprint do
        assign(socket, error: gettext("Ce poste est celui que vous utilisez."), info: nil)
      else
        case Auth.revoke_certificate(socket.assigns.account.id, fingerprint) do
          {:ok, _account} -> assign(socket, error: nil, info: gettext("Poste révoqué."))
          {:error, reason} -> assign(socket, error: revocation_error(reason), info: nil)
        end
      end

    {:noreply, socket |> assign(:pending_certificate, nil) |> load_account()}
  end

  defp revocation_error(:last_passkey), do: gettext("C'est votre dernière passkey.")
  defp revocation_error(:last_certificate), do: gettext("C'est votre dernier poste.")
  defp revocation_error(_reason), do: gettext("Révocation impossible.")

  defp current_fingerprint(socket) do
    case socket.assigns.current_scope.certificate do
      nil -> nil
      certificate -> certificate.fingerprint
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:account} locale={@locale} scope={@current_scope} />

    <div id="account" phx-hook="Passkey" class="mx-auto max-w-3xl space-y-8 p-6">
      <h1 class="text-lg font-semibold">{gettext("Mon compte")} — {@account.id}</h1>

      <div :if={@error} class="rounded bg-error/20 p-3 text-sm">{@error}</div>
      <div :if={@info} class="rounded bg-success/20 p-3 text-sm">{@info}</div>

      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase text-base-content/70">{gettext("Passkeys")}</h2>

        <table class="w-full text-left text-sm">
          <thead>
            <tr>
              <th class="border-b p-2">{gettext("Libellé")}</th>
              <th class="border-b p-2">{gettext("Enregistrée le")}</th>
              <th class="border-b p-2">{gettext("actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={passkey <- @account.passkeys}>
              <td class="border-b p-2">{passkey.label}</td>
              <td class="border-b p-2">{date(passkey.created_at)}</td>
              <td class="border-b p-2">
                <button
                  :if={length(@account.passkeys) > 1}
                  type="button"
                  phx-click="ask_revoke_passkey"
                  phx-value-id={encode(passkey.credential_id)}
                  class="btn btn-xs btn-error"
                >
                  {gettext("Révoquer")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="add_passkey" class="flex items-end gap-2 text-sm">
          <div>
            <label for="new-passkey-label" class="mb-1 block text-xs uppercase">
              {gettext("Libellé")}
            </label>
            <input
              id="new-passkey-label"
              name="label"
              required
              value={gettext("nouvelle passkey")}
              class="input input-sm"
            />
          </div>
          <button type="submit" class="btn btn-sm btn-primary">
            {gettext("Ajouter une passkey")}
          </button>
        </form>
      </section>

      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase text-base-content/70">{gettext("Mes postes")}</h2>

        <table class="w-full text-left text-sm">
          <thead>
            <tr>
              <th class="border-b p-2">{gettext("Libellé")}</th>
              <th class="border-b p-2">{gettext("Émis le")}</th>
              <th class="border-b p-2">{gettext("Expire le")}</th>
              <th class="border-b p-2">{gettext("État")}</th>
              <th class="border-b p-2">{gettext("actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={certificate <- @account.certificates}>
              <td class="border-b p-2">{certificate.label}</td>
              <td class="border-b p-2">{date(certificate.issued_at)}</td>
              <td class="border-b p-2">{date(certificate.expires_at)}</td>
              <td class="border-b p-2">{certificate_state(certificate, @current_fingerprint)}</td>
              <td class="border-b p-2">
                <button
                  :if={
                    is_nil(certificate.revoked_at) and
                      certificate.fingerprint != @current_fingerprint
                  }
                  type="button"
                  phx-click="ask_revoke_certificate"
                  phx-value-fingerprint={certificate.fingerprint}
                  class="btn btn-xs btn-error"
                >
                  {gettext("Révoquer")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="add_certificate" class="flex items-end gap-2 text-sm">
          <div>
            <label for="new-cert-label" class="mb-1 block text-xs uppercase">
              {gettext("Libellé du poste")}
            </label>
            <input
              id="new-cert-label"
              name="label"
              required
              value={gettext("nouveau poste")}
              class="input input-sm"
            />
          </div>
          <button type="submit" class="btn btn-sm btn-primary">
            {gettext("Émettre un certificat")}
          </button>
        </form>

        <div :if={@issued} class="rounded bg-base-200 p-3 text-sm">
          <p>
            {gettext("Mot de passe du fichier, affiché une seule fois :")}
            <code class="select-all rounded bg-base-300 px-2 py-1 font-mono">
              {@issued.password}
            </code>
          </p>
          <p class="mt-1 font-semibold">
            {gettext("Importez le fichier, puis fermez complètement le navigateur avant de revenir.")}
          </p>
        </div>
      </section>

      <.admin_confirm_modal
        :if={@pending_passkey}
        id="revoke-passkey-modal"
        title={gettext("Révoquer cette passkey")}
        confirm_event="revoke_passkey"
        cancel_event="cancel_revoke_passkey"
        confirm_values={%{"credential" => @pending_passkey}}
        confirm_label={gettext("Révoquer")}
      >
        {gettext("Cette passkey ne pourra plus ouvrir de session.")}
      </.admin_confirm_modal>

      <.admin_confirm_modal
        :if={@pending_certificate}
        id="revoke-certificate-modal"
        title={gettext("Révoquer ce poste")}
        confirm_event="revoke_certificate"
        cancel_event="cancel_revoke_certificate"
        confirm_values={%{"fingerprint" => @pending_certificate}}
        confirm_label={gettext("Révoquer")}
      >
        {gettext("Ce poste perdra l'accès immédiatement, même s'il a une session ouverte.")}
      </.admin_confirm_modal>
    </div>
    """
  end

  defp certificate_state(%{revoked_at: %DateTime{}}, _current), do: gettext("révoqué")

  defp certificate_state(certificate, current) do
    cond do
      certificate.fingerprint == current -> gettext("poste courant")
      DateTime.compare(certificate.expires_at, DateTime.utc_now()) != :gt -> gettext("expiré")
      true -> gettext("actif")
    end
  end

  defp date(nil), do: "—"
  defp date(time), do: Calendar.strftime(time, "%d/%m/%Y")

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
end
