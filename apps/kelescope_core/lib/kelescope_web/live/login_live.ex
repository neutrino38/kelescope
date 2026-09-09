defmodule KelescopeWeb.LoginLive do
  @moduledoc """
  Opens a session on a workstation that already holds a client certificate.

  The certificate has named the account, so nothing is typed here: only the
  passkey ceremony remains. A LiveView cannot write a cookie, hence the signed
  handover token posted to `KelescopeWeb.SessionController`.
  """
  use KelescopeWeb, :live_view

  alias Kelescope.Auth
  alias Kelescope.Auth.Passkey
  alias KelescopeWeb.AuthHook
  alias KelescopeWeb.SessionController

  def mount(_params, session, socket) do
    if Auth.dev_mode?() do
      {:ok, redirect(socket, to: "/")}
    else
      fingerprint = AuthHook.fingerprint(socket, session)

      socket =
        socket
        |> assign(:page_title, gettext("Connexion"))
        |> assign(:fingerprint, fingerprint)
        |> assign(:account, nil)
        |> assign(:challenge, nil)
        |> assign(:token, nil)
        |> assign(:error, nil)
        |> assign(:wrong_host, wrong_host?(session))
        |> assign_state(Auth.resolve(fingerprint, session))

      {:ok, socket}
    end
  end

  defp assign_state(socket, {:ok, _scope}), do: redirect(socket, to: "/")

  defp assign_state(socket, {:passkey_required, account, _certificate}) do
    if account.passkeys == [] do
      assign(socket, :state, :no_passkey)
    else
      socket |> assign(:state, :ready) |> assign(:account, account)
    end
  end

  defp assign_state(socket, {:error, :no_certificate}),
    do: assign(socket, :state, :no_certificate)

  defp assign_state(socket, {:error, _reason}), do: assign(socket, :state, :refused)

  def handle_event("authenticate", _params, socket) do
    {challenge, options} = Passkey.authentication_challenge(socket.assigns.account)

    {:noreply,
     socket
     |> assign(:challenge, challenge)
     |> assign(:error, nil)
     |> push_event("passkey:get", options)}
  end

  def handle_event("passkey:result", response, socket) do
    %{account: account, challenge: challenge, fingerprint: fingerprint} = socket.assigns

    with {:ok, verified} <- Passkey.verify_authentication(response, challenge),
         {:ok, _account} <-
           Auth.update_sign_count(account.id, verified.credential_id, verified.sign_count) do
      {:noreply, assign(socket, :token, SessionController.sign_token(account.id, fingerprint))}
    else
      _error ->
        {:noreply, assign(socket, :error, gettext("La passkey n'a pas été acceptée."))}
    end
  end

  def handle_event("passkey:error", %{"message" => message}, socket) do
    {:noreply, assign(socket, :error, message)}
  end

  def render(assigns) do
    ~H"""
    <div id="login" phx-hook="Passkey" class="mx-auto max-w-lg p-6">
      <h1 class="mb-4 text-lg font-semibold">{gettext("Connexion à kelescope")}</h1>

      <div :if={@wrong_host} class="mb-4 rounded bg-warning/20 p-3 text-sm">
        {gettext(
          "Cette instance doit être appelée par le nom %{host}. Une adresse IP ou un autre alias fait échouer la passkey.",
          host: Passkey.rp_id()
        )}
      </div>

      <div :if={@error} class="mb-4 rounded bg-error/20 p-3 text-sm">{@error}</div>

      <div :if={@state == :no_certificate} class="space-y-3 text-sm">
        <p class="font-semibold">{gettext("Poste non enrôlé")}</p>
        <p>
          {gettext(
            "Ce navigateur ne présente aucun certificat kelescope. Enrôlez ce poste avec le code d'invitation fourni par un administrateur général."
          )}
        </p>
        <.link navigate={~p"/enroll"} class="btn btn-sm btn-primary">
          {gettext("Enrôler ce poste")}
        </.link>
      </div>

      <div :if={@state == :refused} class="space-y-3 text-sm">
        <p class="font-semibold">{gettext("Poste refusé")}</p>
        <p>
          {gettext(
            "Le certificat présenté n'ouvre aucun accès. Demandez une réinitialisation à un administrateur général."
          )}
        </p>
      </div>

      <div :if={@state == :no_passkey} class="space-y-3 text-sm">
        <p class="font-semibold">{gettext("Aucune passkey enregistrée")}</p>
        <p>
          {gettext(
            "Ce poste est reconnu, mais le compte n'a pas de passkey. Terminez l'enrôlement pour en enregistrer une."
          )}
        </p>
        <.link navigate={~p"/enroll"} class="btn btn-sm btn-primary">
          {gettext("Enregistrer une passkey")}
        </.link>
      </div>

      <div :if={@state == :ready and is_nil(@token)} class="space-y-3 text-sm">
        <p>{gettext("Poste reconnu. Confirmez avec votre passkey.")}</p>
        <button type="button" phx-click="authenticate" class="btn btn-sm btn-primary">
          {gettext("Se connecter")}
        </button>
      </div>

      <form
        :if={@token}
        id="session-form"
        phx-hook="AutoSubmit"
        action={~p"/session"}
        method="post"
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <input type="hidden" name="token" value={@token} />
        <button type="submit" class="btn btn-sm btn-primary">{gettext("Continuer")}</button>
      </form>
    </div>
    """
  end

  defp wrong_host?(session) do
    case session["request_host"] do
      nil -> false
      host -> host != Passkey.rp_id()
    end
  end
end
