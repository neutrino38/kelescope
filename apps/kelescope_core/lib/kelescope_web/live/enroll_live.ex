defmodule KelescopeWeb.EnrollLive do
  @moduledoc """
  Enrolment of an administrator: identifier and invitation code, then a passkey,
  then a client certificate downloaded as a PKCS#12 bundle.

  This page is reachable without a client certificate — it is the only one.
  """
  use KelescopeWeb, :live_view

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey

  def mount(_params, _session, socket) do
    if Auth.dev_mode?() do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok,
       socket
       |> assign(:page_title, gettext("Enrôlement"))
       |> assign(:step, :code)
       |> assign(:account, nil)
       |> assign(:challenge, nil)
       |> assign(:issued, nil)
       |> assign(:error, nil)}
    end
  end

  def handle_event("redeem", %{"admin_id" => id, "code" => code}, socket) do
    case Auth.redeem_invitation(String.trim(id), String.trim(code)) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:account, account)
         |> assign(:error, nil)
         |> assign(:step, :passkey)}

      {:error, :invalid_invitation} ->
        {:noreply, assign(socket, :error, gettext("Identifiant ou code invalide, ou expiré."))}
    end
  end

  def handle_event("register_passkey", %{"label" => label}, socket) do
    {challenge, options} = Passkey.registration_challenge(socket.assigns.account)

    {:noreply,
     socket
     |> assign(:challenge, challenge)
     |> assign(:passkey_label, String.trim(label))
     |> assign(:error, nil)
     |> push_event("passkey:create", options)}
  end

  def handle_event("passkey:result", response, socket) do
    %{account: account, challenge: challenge} = socket.assigns

    with {:ok, registered} <- Passkey.verify_registration(response, challenge),
         {:ok, account} <-
           Auth.add_passkey(account.id, Map.put(registered, :label, passkey_label(socket))) do
      {:noreply, socket |> assign(:account, account) |> assign(:step, :certificate)}
    else
      _error ->
        {:noreply, assign(socket, :error, gettext("La passkey n'a pas pu être enregistrée."))}
    end
  end

  def handle_event("passkey:error", %{"message" => message}, socket) do
    {:noreply, assign(socket, :error, message)}
  end

  def handle_event("skip_passkey", _params, socket) do
    {:noreply, assign(socket, :step, :certificate)}
  end

  def handle_event("issue_certificate", %{"label" => label}, socket) do
    account = socket.assigns.account

    case Auth.issue_certificate(account.id, String.trim(label)) do
      {:ok, issued} ->
        {:ok, _account} = Auth.consume_invitation(account.id)

        {:noreply,
         socket
         |> assign(:issued, Map.delete(issued, :pkcs12))
         |> assign(:step, :done)
         |> assign(:error, nil)
         |> push_event("download", %{
           "filename" => "kelescope-#{account.id}.p12",
           "content_type" => "application/x-pkcs12",
           "data" => Base.encode64(issued.pkcs12)
         })}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Le certificat n'a pas pu être émis."))}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="enroll" phx-hook="Passkey" class="mx-auto max-w-lg p-6">
      <div class="mb-4 flex items-center justify-end gap-3">
        <.locale_switch locale={@locale} />
        <.font_size />
      </div>
      <h1 class="mb-4 text-lg font-semibold">{gettext("Enrôlement d'un poste")}</h1>

      <div :if={@error} class="mb-4 rounded bg-error/20 p-3 text-sm">{@error}</div>

      <form :if={@step == :code} phx-submit="redeem" class="space-y-3 text-sm">
        <div>
          <label for="enroll-id" class="mb-1 block text-xs uppercase">{gettext("Identifiant")}</label>
          <input id="enroll-id" name="admin_id" required class="input input-sm w-full" />
        </div>
        <div>
          <label for="enroll-code" class="mb-1 block text-xs uppercase">
            {gettext("Code d'invitation")}
          </label>
          <input id="enroll-code" name="code" required class="input input-sm w-full" />
        </div>
        <button type="submit" class="btn btn-sm btn-primary">{gettext("Continuer")}</button>
      </form>

      <form :if={@step == :passkey} phx-submit="register_passkey" class="space-y-3 text-sm">
        <p>{gettext("Enregistrez la passkey qui prouvera votre identité à chaque connexion.")}</p>
        <div>
          <label for="passkey-label" class="mb-1 block text-xs uppercase">
            {gettext("Libellé de la passkey")}
          </label>
          <input
            id="passkey-label"
            name="label"
            required
            value={gettext("ma passkey")}
            class="input input-sm w-full"
          />
        </div>
        <div class="flex gap-2">
          <button type="submit" class="btn btn-sm btn-primary">
            {gettext("Enregistrer la passkey")}
          </button>
          <button
            :if={@account.passkeys != []}
            type="button"
            phx-click="skip_passkey"
            class="btn btn-sm"
          >
            {gettext("Passer cette étape")}
          </button>
        </div>
      </form>

      <form :if={@step == :certificate} phx-submit="issue_certificate" class="space-y-3 text-sm">
        <p>{gettext("Téléchargez maintenant le certificat de ce poste.")}</p>
        <div>
          <label for="cert-label" class="mb-1 block text-xs uppercase">
            {gettext("Libellé du poste")}
          </label>
          <input
            id="cert-label"
            name="label"
            required
            value={gettext("mon poste")}
            class="input input-sm w-full"
          />
        </div>
        <button type="submit" class="btn btn-sm btn-primary">
          {gettext("Émettre le certificat")}
        </button>
      </form>

      <div :if={@step == :done} class="space-y-3 text-sm">
        <p class="font-semibold">{gettext("Certificat émis")}</p>
        <p>
          {gettext("Mot de passe du fichier, affiché une seule fois :")}
          <code class="select-all rounded bg-base-300 px-2 py-1 font-mono">{@issued.password}</code>
        </p>
        <ol class="list-decimal space-y-1 pl-5">
          <li>{gettext("Importez le fichier .p12 dans le navigateur ou le magasin du système.")}</li>
          <li class="font-semibold">
            {gettext(
              "Fermez complètement le navigateur, puis rouvrez-le : une connexion TLS déjà ouverte ne présente pas le nouveau certificat."
            )}
          </li>
          <li>{gettext("Revenez sur kelescope et confirmez avec votre passkey.")}</li>
        </ol>
        <p class="text-xs text-base-content/70">
          {gettext("Expire le %{date}.", date: Calendar.strftime(@issued.expires_at, "%d/%m/%Y"))}
        </p>
      </div>
    </div>
    """
  end

  defp passkey_label(socket), do: socket.assigns[:passkey_label] || gettext("ma passkey")
end
