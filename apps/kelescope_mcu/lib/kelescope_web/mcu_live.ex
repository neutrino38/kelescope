defmodule KelescopeWeb.McuLive do
  use KelescopeWeb, {:live_view, KelescopeWeb.Mcu.Gettext}

  alias Kelescope.Auth.Scope
  alias Kelescope.Kelixip.Control
  alias Kelescope.Kelixip.Link

  # Kelix.Mod.Mcu.Vocabulary.@mosaics (elixip), wire order — kept in sync by hand,
  # see docs/conception/phase4-mcu/SPEC.md "Risques".
  @layouts [
    %{id: 0, name: "1x1"},
    %{id: 1, name: "2x2"},
    %{id: 2, name: "3x3"},
    %{id: 3, name: "3+4"},
    %{id: 4, name: "1+7"},
    %{id: 5, name: "1+5"},
    %{id: 6, name: "1+1"},
    %{id: 7, name: "pip1"},
    %{id: 8, name: "pip3"},
    %{id: 9, name: "4x4"},
    %{id: 10, name: "1+4"},
    %{id: 11, name: "2+8"}
  ]

  # Kelix.Mod.Mcu.Vocabulary.@sizes (elixip) — shared by `video.size` and
  # `layout.size` (the mosaic canvas is the encoded picture, elixip keeps the two
  # equal on its side). Kept in sync by hand, same as @layouts above.
  @video_sizes [
    %{id: 0, name: "qcif"},
    %{id: 1, name: "cif"},
    %{id: 2, name: "vga"},
    %{id: 3, name: "pal"},
    %{id: 4, name: "hvga"},
    %{id: 5, name: "qvga"},
    %{id: 6, name: "hd720p"},
    %{id: 7, name: "wqvga"},
    %{id: 14, name: "xga"},
    %{id: 15, name: "wvga"}
  ]

  # MediaServerMendoozeSdp.@video_codecs (dépôt elixip, apps/elixip2) — the codecs
  # `preferred_video_codec` may name. Kept in sync by hand, same as @layouts.
  @video_codecs ~w(H264 VP8 AV1)

  # Kelix.Mod.Mcu.Vocabulary.@vads (elixip) — the conference-level VAD (voice
  # activity detection) mode. Kept in sync by hand, same as @layouts.
  @vad_modes [
    %{id: 0, name: "none"},
    %{id: 1, name: "basic"},
    %{id: 2, name: "full"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kelescope.PubSub, "kelixip:conferences")
    end

    {_status, domains} = Kelescope.Kelixip.DomainsLink.snapshot()

    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       conferences: visible(Kelescope.Kelixip.ConferencesPoller.snapshot(), scope),
       expanded: nil,
       detail: nil,
       form_mode: nil,
       form_error: nil,
       form_params: %{},
       pending_create: nil,
       pending_delete: nil,
       error: nil,
       layouts: @layouts,
       video_sizes: @video_sizes,
       video_codecs: @video_codecs,
       vad_modes: @vad_modes,
       domain_names: scope |> Scope.visible_domains(Enum.map(domains, & &1.name)) |> Enum.sort()
     )}
  end

  @impl true
  def handle_event("toggle", %{"uid" => uid}, socket) do
    if socket.assigns.expanded == uid do
      {:noreply, assign(socket, expanded: nil, detail: nil)}
    else
      {:noreply, assign(socket, expanded: uid, detail: fetch_conference(uid))}
    end
  end

  def handle_event("refresh_detail", %{"uid" => uid}, socket) do
    {:noreply, assign(socket, :detail, fetch_conference(uid))}
  end

  def handle_event("new_conference", _params, socket) do
    {:noreply, assign(socket, form_mode: :create, form_error: nil, form_params: form_params(nil))}
  end

  def handle_event("edit_conference", %{"uid" => uid}, socket) do
    conf = edit_conf({:edit, uid}, socket.assigns.detail)

    {:noreply,
     assign(socket, form_mode: {:edit, uid}, form_error: nil, form_params: form_params(conf))}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, form_mode: nil, form_error: nil)}
  end

  # A section hidden by its media checkbox keeps its values here, so re-checking
  # the media restores what the user had typed rather than the defaults.
  def handle_event("form_changed", params, socket) do
    merged = Map.merge(socket.assigns.form_params, Map.delete(params, "_target"))
    {:noreply, assign(socket, :form_params, merged)}
  end

  def handle_event("submit_conference_form", params, socket) do
    case socket.assigns.form_mode do
      :create ->
        {:noreply, assign(socket, pending_create: params, form_mode: nil, form_error: nil)}

      {:edit, uid} ->
        if not may?(socket, uid) do
          {:noreply, assign(socket, form_mode: nil, error: forbidden_message())}
        else
          update_conference(socket, uid, params)
        end
    end
  end

  def handle_event("cancel_create_conference", _params, socket) do
    {:noreply, assign(socket, :pending_create, nil)}
  end

  def handle_event("confirm_create_conference", params, socket) do
    scope = socket.assigns.current_scope

    socket =
      cond do
        not Scope.can?(scope, :conference, Map.get(params, "domain")) ->
          assign(socket, pending_create: nil, error: forbidden_message())

        true ->
          case Control.create_conference(Link.target_node(), form_attrs(params), Scope.id(scope)) do
            {:ok, _reply} ->
              socket |> assign(pending_create: nil, error: nil) |> refresh_list()

            {:error, reason} ->
              assign(socket, pending_create: nil, error: create_error_message(reason))
          end
      end

    {:noreply, socket}
  end

  def handle_event("request_delete_conference", %{"uid" => uid}, socket) do
    if may?(socket, uid),
      do: {:noreply, assign(socket, :pending_delete, uid)},
      else: {:noreply, socket}
  end

  def handle_event("cancel_delete_conference", _params, socket) do
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("confirm_delete_conference", %{"uid" => uid}, socket) do
    if not may?(socket, uid) do
      {:noreply, assign(socket, pending_delete: nil, error: forbidden_message())}
    else
      delete_conference(socket, uid)
    end
  end

  def handle_event("start_recording", %{"uid" => uid}, socket) do
    socket =
      case may?(socket, uid) && Control.start_recording(Link.target_node(), uid) do
        false -> assign(socket, :error, forbidden_message())
        {:ok, _} -> socket |> assign(detail: fetch_conference(uid), error: nil) |> refresh_list()
        {:error, reason} -> assign(socket, :error, recording_error_message(reason))
      end

    {:noreply, socket}
  end

  def handle_event("stop_recording", %{"uid" => uid}, socket) do
    socket =
      case may?(socket, uid) && Control.stop_recording(Link.target_node(), uid) do
        false -> assign(socket, :error, forbidden_message())
        {:ok, _} -> socket |> assign(detail: fetch_conference(uid), error: nil) |> refresh_list()
        {:error, reason} -> assign(socket, :error, recording_error_message(reason))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:kelixip_conferences, conferences}, socket) do
    {:noreply, assign(socket, :conferences, visible(conferences, socket.assigns.current_scope))}
  end

  defp fetch_conference(uid) do
    with {:ok, conf} <- Control.conference(Link.target_node(), uid) do
      participants = Enum.map(conf.participants, &with_stats(uid, &1))
      {:ok, %{conf | participants: participants}}
    end
  end

  defp with_stats(uid, participant) do
    case Control.participant(Link.target_node(), uid, participant.part_id) do
      {:ok, full} -> Map.put(participant, :stats, Map.get(full, :stats, %{}))
      {:error, _reason} -> Map.put(participant, :stats, %{})
    end
  end

  defp update_conference(socket, uid, params) do
    case Control.update_conference(Link.target_node(), uid, form_attrs(params)) do
      {:ok, _conf} ->
        {:noreply,
         socket
         |> assign(form_mode: nil, form_error: nil, detail: fetch_conference(uid))
         |> refresh_list()}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, inspect(reason))}
    end
  end

  defp delete_conference(socket, uid) do
    socket =
      case Control.delete_conference(
             Link.target_node(),
             uid,
             Scope.id(socket.assigns.current_scope)
           ) do
        {:ok, _} ->
          socket
          |> assign(pending_delete: nil, error: nil)
          |> maybe_clear_expanded(uid)
          |> refresh_list()

        {:error, reason} ->
          assign(socket, pending_delete: nil, error: delete_error_message(reason))
      end

    {:noreply, socket}
  end

  defp forbidden_message,
    do: gettext("Action refusée : ce domaine est hors de votre portée.")

  defp refresh_list(socket) do
    case Control.list_conferences(Link.target_node()) do
      {:ok, conferences} ->
        assign(socket, :conferences, visible(conferences, socket.assigns.current_scope))

      {:error, _reason} ->
        socket
    end
  end

  # Filtering happens before the assign, so a conference outside the scope never
  # reaches the socket, let alone the DOM.
  defp visible(nil, _scope), do: nil

  defp visible(conferences, scope) do
    Enum.filter(conferences, &Scope.sees_domain?(scope, Map.get(&1, :domain)))
  end

  defp conference_domain(socket, uid) do
    case Enum.find(socket.assigns.conferences || [], &(&1.uid == uid)) do
      nil -> nil
      conf -> Map.get(conf, :domain)
    end
  end

  # A hidden button is no protection: the event carries a uid or a domain the
  # browser chose, so the scope is checked again here.
  defp may?(socket, uid) do
    Scope.can?(socket.assigns.current_scope, :conference, conference_domain(socket, uid))
  end

  defp maybe_clear_expanded(%{assigns: %{expanded: uid}} = socket, uid),
    do: assign(socket, expanded: nil, detail: nil)

  defp maybe_clear_expanded(socket, _uid), do: socket

  defp edit_conf({:edit, _uid}, {:ok, conf}), do: conf
  defp edit_conf(_mode, _detail), do: nil

  # The form's own state, string-keyed exactly like the params `phx-change` sends
  # back, so re-rendering the modal (a media checkbox showing or hiding a
  # section) keeps what the user typed instead of falling back to the defaults.
  defp form_params(nil) do
    %{
      "domain" => "",
      "did" => "",
      "name" => "",
      "max_participants" => "20",
      "destroy_when_empty" => "false",
      "media_audio" => "true",
      "media_video" => "true",
      "media_text" => "true",
      "rate" => "32000",
      "vad" => "1",
      "video_size" => "6",
      "video_bitrate" => "1500",
      "preferred_video_codec" => "",
      "layout_comp" => "1",
      "layout_auto" => "true",
      "logo" => ""
    }
  end

  defp form_params(conf) do
    %{
      "name" => conf.name || "",
      "max_participants" => to_string(conf.max_participants),
      "destroy_when_empty" => to_string(conf.destroy_when_empty),
      "media_audio" => to_string(:audio in conf.medias),
      "media_video" => to_string(:video in conf.medias),
      "media_text" => to_string(:text in conf.medias),
      "rate" => to_string(conf.rate),
      "vad" => to_string(conf.vad),
      "video_size" => to_string(conf.video.size),
      "video_bitrate" => to_string(conf.video.bitrate),
      "preferred_video_codec" => conf.preferred_video_codec || "",
      "layout_comp" => to_string(conf.layout.comp),
      "layout_auto" => to_string(conf.layout.auto),
      "logo" => conf.logo || ""
    }
  end

  # Flat form params (create step 1, or an edit submit) -> the string-keyed attrs
  # Kelescope.Kelixip.Control.create_conference/3 and update_conference/3 expect.
  defp form_attrs(params) do
    %{}
    |> maybe_put_string(params, "domain")
    |> maybe_put_string(params, "did")
    |> maybe_put_string(params, "name")
    |> maybe_put_int(params, "max_participants")
    |> maybe_put_int(params, "vad")
    |> maybe_put_int(params, "rate")
    |> maybe_put_string(params, "logo")
    |> maybe_put_medias(params)
    |> Map.put("destroy_when_empty", Map.get(params, "destroy_when_empty") == "true")
    |> maybe_put_layout(params)
    |> maybe_put_video(params)
    |> maybe_put_string_or_empty(params, "preferred_video_codec")
  end

  # "" is a value here — the form's "aucune préférence", which clears the
  # preference. Only an absent key (video section hidden) leaves it alone.
  defp maybe_put_string_or_empty(attrs, params, key) do
    case Map.fetch(params, key) do
      :error -> attrs
      {:ok, v} -> Map.put(attrs, key, v)
    end
  end

  defp maybe_put_string(attrs, params, key) do
    case Map.get(params, key) do
      v when v in [nil, ""] -> attrs
      v -> Map.put(attrs, key, v)
    end
  end

  defp maybe_put_int(attrs, params, key) do
    case Map.get(params, key) do
      v when v in [nil, ""] -> attrs
      v -> Map.put(attrs, key, String.to_integer(v))
    end
  end

  # elixip refuses an empty list ("a conference that answers nothing"): omitted
  # (nothing checked) means "leave as configured", never an explicit empty list.
  defp maybe_put_medias(attrs, params) do
    medias =
      [{"media_audio", "audio"}, {"media_video", "video"}, {"media_text", "text"}]
      |> Enum.filter(fn {key, _name} -> Map.get(params, key) == "true" end)
      |> Enum.map(fn {_key, name} -> name end)

    if medias == [], do: attrs, else: Map.put(attrs, "medias", medias)
  end

  # No `layout_*` at all means the mosaic section was hidden (video unchecked):
  # kelescope then omits `layout`, and elixip keeps the configured one.
  defp maybe_put_layout(attrs, params) do
    if Map.has_key?(params, "layout_auto") or Map.has_key?(params, "layout_comp") do
      layout =
        %{"auto" => Map.get(params, "layout_auto") == "true"}
        |> maybe_put_layout_comp(params)

      Map.put(attrs, "layout", layout)
    else
      attrs
    end
  end

  defp maybe_put_layout_comp(layout, params) do
    case Map.get(params, "layout_comp") do
      v when v in [nil, ""] -> layout
      v -> Map.put(layout, "comp", String.to_integer(v))
    end
  end

  defp maybe_put_video(attrs, params) do
    video =
      %{}
      |> maybe_put_video_field(params, "video_size", "size")
      |> maybe_put_video_field(params, "video_bitrate", "bitrate")

    if video == %{}, do: attrs, else: Map.put(attrs, "video", video)
  end

  defp maybe_put_video_field(video, params, param_key, video_key) do
    case Map.get(params, param_key) do
      v when v in [nil, ""] -> video
      v -> Map.put(video, video_key, String.to_integer(v))
    end
  end

  defp create_error_message(:did_in_use),
    do: gettext("Ce DID est déjà utilisé par une conférence de ce domaine.")

  defp create_error_message(:did_required),
    do:
      gettext(
        "Aucun DID donné, et aucune plage de DID configurée pour ce domaine : saisissez un DID."
      )

  defp create_error_message(:no_did_available),
    do: gettext("Plus aucun DID libre dans la plage de ce domaine : saisissez un DID.")

  defp create_error_message(reason), do: gettext("Erreur : %{reason}", reason: inspect(reason))

  defp delete_error_message(:not_empty),
    do: gettext("Impossible de détruire : la conférence a encore des participants.")

  defp delete_error_message(reason), do: gettext("Erreur : %{reason}", reason: inspect(reason))

  defp recording_error_message(:already_recording),
    do: gettext("Cette conférence est déjà en cours d'enregistrement.")

  defp recording_error_message(:not_recording),
    do: gettext("Cette conférence n'est pas en cours d'enregistrement.")

  defp recording_error_message(reason), do: gettext("Erreur : %{reason}", reason: inspect(reason))

  defp layout_name(id), do: Enum.find_value(@layouts, "?", &(&1.id == id && &1.name))

  defp video_size_name(id), do: Enum.find_value(@video_sizes, "?", &(&1.id == id && &1.name))

  defp vad_mode_name(id), do: Enum.find_value(@vad_modes, "?", &(&1.id == id && &1.name))

  @impl true
  def render(assigns) do
    ~H"""
    <.nav current={:mcu} locale={@locale} scope={@current_scope} />
    <div class="p-6">
      <p :if={@error} class="mb-4 rounded bg-error/15 px-3 py-2 text-sm text-error">{@error}</p>

      <.header>
        MCU
        <:actions>
          <.button
            :if={Enum.any?(@domain_names, &Scope.can?(@current_scope, :conference, &1))}
            phx-click="new_conference"
          >
            {gettext("Nouvelle conférence")}
          </.button>
        </:actions>
      </.header>

      <p :if={@conferences == nil} class="text-sm text-base-content/70">{gettext("Chargement…")}</p>

      <div :if={@conferences} class="divide-y rounded border">
        <.conference_row
          :for={c <- @conferences}
          conf={c}
          scope={@current_scope}
          expanded={@expanded == c.uid}
          detail={if @expanded == c.uid, do: @detail}
        />
        <p :if={@conferences == []} class="p-3 text-sm text-base-content/70">
          {gettext("Aucune conférence.")}
        </p>
      </div>
    </div>

    <.conference_form_modal
      :if={@form_mode}
      mode={@form_mode}
      params={@form_params}
      layouts={@layouts}
      video_sizes={@video_sizes}
      video_codecs={@video_codecs}
      vad_modes={@vad_modes}
      domain_names={@domain_names}
      error={@form_error}
    />

    <.admin_confirm_modal
      :if={@pending_create}
      id="create-conference-modal"
      title={gettext("Créer cette conférence")}
      confirm_event="confirm_create_conference"
      cancel_event="cancel_create_conference"
      confirm_values={@pending_create}
      confirm_label={gettext("Créer")}
    >
      {gettext("Domaine")} <strong>{Map.get(@pending_create, "domain")}</strong>
    </.admin_confirm_modal>

    <.admin_confirm_modal
      :if={@pending_delete}
      id="delete-conference-modal"
      title={gettext("Détruire cette conférence")}
      confirm_event="confirm_delete_conference"
      cancel_event="cancel_delete_conference"
      confirm_values={%{"uid" => @pending_delete}}
      confirm_label={gettext("Détruire")}
    >
      {gettext("Cette action est irréversible.")}
    </.admin_confirm_modal>
    """
  end

  attr :conf, :map, required: true
  attr :expanded, :boolean, required: true
  attr :detail, :any, default: nil
  attr :scope, :map, required: true

  defp conference_row(assigns) do
    ~H"""
    <div class="p-3">
      <div
        phx-click="toggle"
        phx-value-uid={@conf.uid}
        class="grid cursor-pointer grid-cols-2 gap-3 sm:grid-cols-6 items-center"
      >
        <span class="text-left font-medium">
          {@conf.name || @conf.uid}
        </span>
        <div class="text-sm">{@conf.domain}</div>
        <div class="text-sm">{@conf.mcu}</div>
        <div class="text-sm">{gettext("%{count} participants", count: @conf.participants)}</div>
        <.layout_icon comp={@conf.layout.comp} class="size-5" />
        <div class="flex items-center gap-2">
          <span :if={@conf.recording} class="badge badge-error badge-sm">REC</span>
          <button
            :if={Scope.can?(@scope, :conference, Map.get(@conf, :domain))}
            type="button"
            phx-click="request_delete_conference"
            phx-value-uid={@conf.uid}
            class="btn btn-xs btn-error"
          >
            {gettext("Détruire")}
          </button>
        </div>
      </div>

      <.conference_detail
        :if={@expanded}
        detail={@detail}
        may_act={Scope.can?(@scope, :conference, Map.get(@conf, :domain))}
      />
    </div>
    """
  end

  attr :detail, :any, default: nil
  attr :may_act, :boolean, default: false

  defp conference_detail(%{detail: nil} = assigns) do
    ~H"""
    <div class="mt-3 border-t pt-3 text-sm text-base-content/70">{gettext("Chargement…")}</div>
    """
  end

  defp conference_detail(%{detail: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <p class="mt-3 border-t pt-3 text-sm text-error">
      {gettext("Impossible de lire la conférence : %{reason}", reason: inspect(@reason))}
    </p>
    """
  end

  defp conference_detail(%{detail: {:ok, full}} = assigns) do
    assigns = assign(assigns, :full, full)

    ~H"""
    <div class="mt-3 border-t pt-3">
      <div class="mb-3 flex items-start gap-4">
        <.layout_icon comp={@full.layout.comp} class="size-10" />
        <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
          <dt class="text-base-content/70">UID</dt>
          <dd>{@full.uid}</dd>
          <dt class="text-base-content/70">DID</dt>
          <dd>{@full.did || "-"}</dd>
          <dt class="text-base-content/70">{gettext("Participants max")}</dt>
          <dd>{@full.max_participants}</dd>
          <dt class="text-base-content/70">{gettext("Détruire quand vide")}</dt>
          <dd>{if @full.destroy_when_empty, do: gettext("oui"), else: gettext("non")}</dd>
          <dt class="text-base-content/70">{gettext("Créée le")}</dt>
          <dd>{@full.created_at}</dd>
          <dt class="text-base-content/70">{gettext("Résolution vidéo")}</dt>
          <dd>{video_size_name(@full.video.size)}</dd>
          <dt class="text-base-content/70">{gettext("Débit vidéo")}</dt>
          <dd>{gettext("%{kbps} kb/s", kbps: @full.video.bitrate)}</dd>
          <dt class="text-base-content/70">{gettext("Codec vidéo préféré")}</dt>
          <dd>{@full.preferred_video_codec || gettext("aucune préférence")}</dd>
          <dt class="text-base-content/70">{gettext("Mode VAD")}</dt>
          <dd>{vad_mode_name(@full.vad)}</dd>
          <dt class="text-base-content/70">{gettext("Bascule automatique de mosaïque")}</dt>
          <dd>{if @full.layout.auto, do: gettext("oui"), else: gettext("non")}</dd>
          <dt class="text-base-content/70">{gettext("Fréquence de mixage")}</dt>
          <dd>{gettext("%{khz} kHz", khz: div(@full.rate, 1000))}</dd>
          <dt class="text-base-content/70">{gettext("Médias")}</dt>
          <dd>{Enum.map_join(@full.medias, ", ", &to_string/1)}</dd>
          <dt class="text-base-content/70">Logo</dt>
          <dd>{@full.logo || "-"}</dd>
          <dt :if={@full.stale} class="text-warning">{gettext("état")}</dt>
          <dd :if={@full.stale} class="text-warning">{gettext("obsolète (MCU redémarré)")}</dd>
        </dl>
      </div>

      <div class="mb-3 flex items-center gap-2">
        <span :if={@full.recording} class="text-sm">
          {gettext("Enregistrement en cours")} — {@full.recording}
        </span>
        <button
          :if={@may_act and !!@full.recording}
          type="button"
          phx-click="stop_recording"
          phx-value-uid={@full.uid}
          class="btn btn-xs btn-error"
        >
          {gettext("Arrêter l'enregistrement")}
        </button>
        <button
          :if={@may_act and !@full.recording}
          type="button"
          phx-click="start_recording"
          phx-value-uid={@full.uid}
          class="btn btn-xs"
        >
          {gettext("Démarrer l'enregistrement")}
        </button>
      </div>

      <.table id={"participants-#{@full.uid}"} rows={@full.participants}>
        <:col :let={p} label="id">{p.part_id}</:col>
        <:col :let={p} label={gettext("nom")}>{p.name || "-"}</:col>
        <:col :let={p} label="from">{p.from || "-"}</:col>
        <:col :let={p} label={gettext("état")}>{p.state}</:col>
        <:col :let={p} label={gettext("depuis")}>{p.joined_at || "-"}</:col>
        <:col :let={p} label={gettext("statistiques média")}>
          <.participant_stats stats={Map.get(p, :stats, %{})} />
        </:col>
      </.table>
      <p :if={@full.participants == []} class="text-sm text-base-content/70">
        {gettext("Aucun participant.")}
      </p>

      <div class="mt-3 flex gap-2">
        <button type="button" phx-click="refresh_detail" phx-value-uid={@full.uid} class="btn btn-xs">
          {gettext("Rafraîchir")}
        </button>
        <button
          :if={@may_act}
          type="button"
          phx-click="edit_conference"
          phx-value-uid={@full.uid}
          class="btn btn-xs"
        >
          {gettext("Modifier les propriétés")}
        </button>
      </div>
    </div>
    """
  end

  attr :comp, :integer, required: true
  attr :class, :any, default: "size-6"

  defp layout_icon(assigns) do
    ~H"""
    <img
      src={"/images/layouts/#{@comp}.svg"}
      alt={layout_name(@comp)}
      title={layout_name(@comp)}
      class={@class}
    />
    """
  end

  attr :stats, :map, required: true

  defp participant_stats(%{stats: stats} = assigns) when map_size(stats) == 0 do
    ~H"""
    <span class="text-base-content/50">-</span>
    """
  end

  defp participant_stats(assigns) do
    ~H"""
    <div class="text-xs whitespace-nowrap">
      <div :for={{media, s} <- @stats}>
        {media}: ↓{s.num_recv_packets}p ↑{s.num_send_packets}p
        <span :if={s.lost_recv_packets > 0} class="text-warning">
          ({s.lost_recv_packets} {gettext("perdus")})
        </span>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp form_section(assigns) do
    ~H"""
    <section class="mb-4">
      <h3 class="mb-2 border-b pb-1 text-xs font-semibold uppercase text-base-content/70">
        {@title}
      </h3>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :mode, :any, required: true
  attr :params, :map, required: true
  attr :layouts, :list, required: true
  attr :video_sizes, :list, required: true
  attr :video_codecs, :list, required: true
  attr :vad_modes, :list, required: true
  attr :domain_names, :list, required: true
  attr :error, :string, default: nil

  defp conference_form_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      phx-window-keydown="cancel_form"
      phx-key="escape"
    >
      <form
        id="conference-form"
        phx-submit="submit_conference_form"
        phx-change="form_changed"
        phx-click-away="cancel_form"
        class="max-h-[85vh] w-[44rem] max-w-[95vw] overflow-y-auto rounded bg-base-200 p-4 shadow-lg"
      >
        <h2 class="mb-3 text-sm font-semibold uppercase text-base-content/70">
          {if @mode == :create,
            do: gettext("Nouvelle conférence"),
            else: gettext("Propriétés de la conférence")}
        </h2>

        <.form_section title={gettext("Paramètres généraux")}>
          <div class="grid grid-cols-1 gap-x-6 sm:grid-cols-2">
            <.input
              :if={@mode == :create}
              type="select"
              name="domain"
              label={gettext("Domaine")}
              options={@domain_names}
              value={@params["domain"]}
              prompt={gettext("Choisir un domaine")}
              required
            />
            <.input
              :if={@mode == :create}
              type="text"
              name="did"
              label="DID"
              value={@params["did"]}
              placeholder={gettext("vide : attribué dans la plage du domaine")}
            />
            <.input type="text" name="name" label={gettext("Nom")} value={@params["name"]} />
            <.input
              type="number"
              name="max_participants"
              label={gettext("Participants max")}
              value={@params["max_participants"]}
              min="1"
            />
            <div class="fieldset mb-2">
              <span class="label mb-1">{gettext("Médias")}</span>
              <div class="flex gap-4">
                <.input
                  type="checkbox"
                  name="media_audio"
                  label="audio"
                  checked={@params["media_audio"] == "true"}
                />
                <.input
                  type="checkbox"
                  name="media_video"
                  label="video"
                  checked={@params["media_video"] == "true"}
                />
                <.input
                  type="checkbox"
                  name="media_text"
                  label="text"
                  checked={@params["media_text"] == "true"}
                />
              </div>
            </div>
            <.input
              type="checkbox"
              name="destroy_when_empty"
              label={gettext("Détruire quand vide")}
              checked={@params["destroy_when_empty"] == "true"}
            />
          </div>
        </.form_section>

        <.form_section
          :if={@params["media_audio"] == "true"}
          title={gettext("Paramètres audio")}
        >
          <div class="grid grid-cols-1 gap-x-6 sm:grid-cols-2">
            <.input
              type="select"
              name="rate"
              label={gettext("Fréquence de mixage")}
              options={[
                {"8 kHz", "8000"},
                {"16 kHz", "16000"},
                {"32 kHz", "32000"},
                {"48 kHz", "48000"}
              ]}
              value={@params["rate"]}
            />
            <.input
              type="select"
              name="vad"
              label={gettext("Mode VAD")}
              options={Enum.map(@vad_modes, &{&1.name, to_string(&1.id)})}
              value={@params["vad"]}
            />
          </div>
        </.form_section>

        <.form_section
          :if={@params["media_video"] == "true"}
          title={gettext("Paramètres vidéo")}
        >
          <div class="grid grid-cols-1 gap-x-6 sm:grid-cols-2">
            <.input
              type="select"
              name="video_size"
              label={gettext("Résolution vidéo")}
              options={Enum.map(@video_sizes, &{&1.name, to_string(&1.id)})}
              value={@params["video_size"]}
            />
            <.input
              type="number"
              name="video_bitrate"
              label={gettext("Débit vidéo (kb/s)")}
              value={@params["video_bitrate"]}
              min="1"
            />
            <.input
              type="select"
              name="preferred_video_codec"
              label={gettext("Codec vidéo préféré")}
              options={[{gettext("aucune préférence"), ""} | Enum.map(@video_codecs, &{&1, &1})]}
              value={@params["preferred_video_codec"]}
            />
          </div>
        </.form_section>

        <.form_section :if={@params["media_video"] == "true"} title={gettext("Mosaïque")}>
          <.layout_picker layouts={@layouts} selected={@params["layout_comp"]} />

          <.input
            type="checkbox"
            name="layout_auto"
            label={gettext("Bascule automatique de mosaïque selon le nombre de participants")}
            checked={@params["layout_auto"] == "true"}
          />

          <.input
            type="text"
            name="logo"
            label="Logo"
            value={@params["logo"]}
            placeholder={gettext("nom de fichier sur le média serveur")}
          />
        </.form_section>

        <p :if={@error} class="mb-3 text-sm text-error">{@error}</p>

        <div class="flex justify-end gap-2">
          <button type="button" phx-click="cancel_form" class="btn btn-sm">
            {gettext("Annuler")}
          </button>
          <button type="submit" class="btn btn-sm btn-primary">
            {if @mode == :create, do: gettext("Continuer"), else: gettext("Enregistrer")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :layouts, :list, required: true
  attr :selected, :string, required: true

  defp layout_picker(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <span class="label mb-1">{gettext("Disposition")}</span>
      <div class="grid grid-cols-6 gap-2">
        <label :for={l <- @layouts} class="flex cursor-pointer flex-col items-center gap-1">
          <input
            type="radio"
            name="layout_comp"
            value={l.id}
            checked={to_string(l.id) == @selected}
            class="peer sr-only"
          />
          <img
            src={"/images/layouts/#{l.id}.svg"}
            alt={l.name}
            class="size-10 rounded border-2 border-transparent peer-checked:border-primary"
          />
          <span class="text-[10px] uppercase text-base-content/70">{l.name}</span>
        </label>
      </div>
    </div>
    """
  end
end
