defmodule KelescopeWeb.McuLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  setup %{conn: conn} do
    admin = admin_fixture(:admin, :all)
    %{conn: log_in(conn, admin), admin: admin}
  end

  test "sert la page en anglais, socle et partie, quand la session le demande", %{conn: conn} do
    {:ok, _view, html} =
      conn
      |> Plug.Test.init_test_session(locale: "en")
      |> live(~p"/mcu")

    # Deux backends Gettext distincts : celui de cette partie et celui du socle.
    assert html =~ "New conference"
    assert html =~ "Increase text size"
    refute html =~ "Nouvelle conférence"
  end

  test "lists the conferences with their layout and recording state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mcu")

    assert html =~ "standup"
    assert html =~ "board-review"
    assert html =~ "example.com"
    assert html =~ "ms1"
    assert html =~ "ms2"
    assert html =~ "REC"
  end

  test "expanding a conference shows its properties and participants", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/mcu")
    refute html =~ "sip:alice@example.com"

    html = view |> element("[phx-click=toggle]", "standup") |> render_click()

    assert html =~ "sip:alice@example.com"
    assert html =~ "sip:bob@example.com"
    refute html =~ "Aucun participant."

    # collapses on a second click
    html = view |> element("[phx-click=toggle]", "standup") |> render_click()
    refute html =~ "sip:alice@example.com"
  end

  test "expanding a conference shows its video resolution, bitrate and preferred codec", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("[phx-click=toggle]", "standup") |> render_click()

    assert html =~ "Résolution vidéo"
    assert html =~ "hd720p"
    assert html =~ "1500 kb/s"
    assert html =~ "H264"

    html = view |> element("[phx-click=toggle]", "board-review") |> render_click()

    assert html =~ "vga"
    assert html =~ "512 kb/s"
    assert html =~ "aucune préférence"
  end

  test "expanding a conference shows its VAD mode and automatic layout switch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("[phx-click=toggle]", "standup") |> render_click()

    assert html =~ "Mode VAD"
    assert html =~ "basic"
    assert html =~ "Bascule automatique de mosaïque"
  end

  test "expanding a conference shows its audio rate, medias and logo", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("[phx-click=toggle]", "standup") |> render_click()

    assert html =~ "32 kHz"
    assert html =~ "audio, video, text"
    refute html =~ "acme-logo.png"

    html = view |> element("[phx-click=toggle]", "board-review") |> render_click()

    assert html =~ "8 kHz"
    assert html =~ "audio, video"
    assert html =~ "acme-logo.png"
  end

  test "expanding a conference shows each participant's media statistics", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("[phx-click=toggle]", "board-review") |> render_click()

    assert html =~ "statistiques média"
    assert html =~ "audio: ↓"
    assert html =~ "video: ↓"
  end

  test "the new-conference form offers domains as a dropdown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("button", "Nouvelle conférence") |> render_click()

    assert html =~ ~s(<select name="domain")
    assert html =~ "example.com"
    assert html =~ "test.local"
    assert html =~ "throwaway.local"
  end

  test "creating a conference with an explicit DID keeps that DID", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "did" => "+33970260299",
      "name" => "temp-did-conf"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-did-conf") |> render_click()

    assert html =~ "+33970260299"
  end

  test "creating a conference on a DID already in use reports the conflict", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "did" => "+33970260240",
      "name" => "temp-did-clash-conf"
    })
    |> render_submit()

    html =
      view
      |> form("#create-conference-modal-form")
      |> render_submit()

    assert html =~ "DID est déjà utilisé"
    refute html =~ "temp-did-clash-conf"
  end

  test "the properties form of an existing conference offers no DID field", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("[phx-click=toggle]", "standup") |> render_click()

    html =
      view
      |> element("button[phx-value-uid='c-standup'][phx-click='edit_conference']")
      |> render_click()

    # elixip declares `did` read-only on conference.update (@conference_readonly,
    # mcu.ex): sending it back would fail the whole update.
    refute html =~ ~s(name="did")
  end

  test "an already-recording conference offers to stop, not start", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("[phx-click=toggle]", "board-review") |> render_click()

    assert html =~ "Arrêter l&#39;enregistrement"
    refute html =~ "Démarrer l&#39;enregistrement"
    assert html =~ "board-review-20260908.mp4"
  end

  test "creating then destroying a conference is traced by kelixip under the connected account",
       %{conn: conn, admin: admin} do
    {:ok, view, html} = live(conn, ~p"/mcu")
    refute html =~ "temp-e2e-conf"

    view |> element("button", "Nouvelle conférence") |> render_click()

    html =
      view
      |> form("form[phx-submit='submit_conference_form']", %{
        "domain" => "example.com",
        "name" => "temp-e2e-conf"
      })
      |> render_submit()

    assert html =~ "Créer cette conférence"

    previous_level = Logger.level()
    Logger.configure(level: :info)

    create_log =
      try do
        capture_log(fn ->
          html =
            view
            |> form("#create-conference-modal-form")
            |> render_submit()

          assert html =~ "temp-e2e-conf"
        end)
      after
        Logger.configure(level: previous_level)
      end

    assert create_log =~ "conference.create domain=example.com"
    assert create_log =~ "admin=#{admin.id}"

    html = view |> element("[phx-click=toggle]", "temp-e2e-conf") |> render_click()
    uid = uid_from_detail(html)

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='request_delete_conference']")
    |> render_click()

    delete_log =
      try do
        Logger.configure(level: :info)

        capture_log(fn ->
          html =
            view
            |> form("#delete-conference-modal-form")
            |> render_submit()

          refute html =~ "temp-e2e-conf"
        end)
      after
        Logger.configure(level: previous_level)
      end

    assert delete_log =~ "conference.delete uid=#{uid}"
    assert delete_log =~ "admin=#{admin.id}"
  end

  test "destroying a non-empty conference reports the conflict instead of crashing", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("[phx-click=toggle]", "standup") |> render_click()

    view
    |> element("button[phx-value-uid='c-standup'][phx-click='request_delete_conference']")
    |> render_click()

    html =
      view
      |> form("#delete-conference-modal-form")
      |> render_submit()

    assert html =~ "encore des participants"
    assert html =~ "standup"
  end

  test "modifying properties changes the layout and name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-props-conf"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-props-conf") |> render_click()
    uid = uid_from_detail(html)

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='edit_conference']")
    |> render_click()

    html =
      view
      |> form("form[phx-submit='submit_conference_form']", %{
        "name" => "temp-props-conf-renamed",
        "layout_comp" => "2"
      })
      |> render_submit()

    assert html =~ "temp-props-conf-renamed"
  end

  test "creating a conference sets its video resolution, bitrate and preferred codec", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-video-conf",
      "video_size" => "2",
      "video_bitrate" => "800",
      "preferred_video_codec" => "VP8"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-video-conf") |> render_click()

    assert html =~ "vga"
    assert html =~ "800 kb/s"
    assert html =~ "VP8"
  end

  test "modifying properties changes the video resolution, bitrate and clears the codec preference",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-video-props-conf",
      "video_size" => "6",
      "preferred_video_codec" => "H264"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-video-props-conf") |> render_click()
    uid = uid_from_detail(html)

    assert html =~ "H264"

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='edit_conference']")
    |> render_click()

    html =
      view
      |> form("form[phx-submit='submit_conference_form']", %{
        "video_size" => "6",
        "video_bitrate" => "2000",
        "preferred_video_codec" => ""
      })
      |> render_submit()

    assert html =~ "2000 kb/s"
    assert html =~ "aucune préférence"
    refute html =~ "H264"
  end

  test "creating a conference sets its VAD mode, then editing it disables automatic layout switching",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-vad-conf",
      "vad" => "2"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-vad-conf") |> render_click()
    uid = uid_from_detail(html)

    assert html =~ "full"

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='edit_conference']")
    |> render_click()

    html =
      view
      |> form("form[phx-submit='submit_conference_form']", %{
        "vad" => "0",
        "layout_auto" => "false"
      })
      |> render_submit()

    assert html =~ "none"

    assert html =~
             ~r/Bascule automatique de mosaïque<\/dt>\s*<dd>\s*non\s*<\/dd>/
  end

  test "creating a conference sets its rate, medias and logo, then editing them changes all three",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-extra-conf",
      "rate" => "16000",
      "media_audio" => "true",
      "media_video" => "true",
      "media_text" => "true",
      "logo" => "welcome.png"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-extra-conf") |> render_click()
    uid = uid_from_detail(html)

    assert html =~ "16 kHz"
    assert html =~ "audio, video, text"
    assert html =~ "welcome.png"

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='edit_conference']")
    |> render_click()

    html =
      view
      |> form("form[phx-submit='submit_conference_form']", %{
        "rate" => "48000",
        "media_audio" => "true",
        "media_video" => "true",
        "media_text" => "false",
        "logo" => "new-logo.png"
      })
      |> render_submit()

    assert html =~ "48 kHz"
    assert html =~ "audio, video"
    assert html =~ "new-logo.png"
    refute html =~ "welcome.png"
  end

  test "unchecking every media on edit leaves the medias unchanged, never clears them", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-medias-conf"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-medias-conf") |> render_click()
    uid = uid_from_detail(html)

    assert html =~ "audio, video, text"

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='edit_conference']")
    |> render_click()

    html =
      view
      |> form("form[phx-submit='submit_conference_form']", %{
        "media_audio" => "false",
        "media_video" => "false",
        "media_text" => "false"
      })
      |> render_submit()

    assert html =~ "audio, video, text"
  end

  test "the audio, video and mosaic sections follow the media checkboxes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("button", "Nouvelle conférence") |> render_click()

    assert html =~ "Paramètres audio"
    assert html =~ "Paramètres vidéo"
    assert html =~ "Mosaïque"

    html =
      view
      |> form("#conference-form", %{"media_audio" => "false", "media_video" => "false"})
      |> render_change()

    refute html =~ "Paramètres audio"
    refute html =~ "Paramètres vidéo"
    refute html =~ "Mosaïque"

    # re-checking a media brings the section back with what was already typed
    html =
      view
      |> form("#conference-form", %{"media_audio" => "true"})
      |> render_change()

    assert html =~ "Paramètres audio"
    refute html =~ "Paramètres vidéo"
  end

  test "editing with the video media unchecked leaves the mosaic settings untouched", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("#conference-form", %{
      "domain" => "example.com",
      "name" => "temp-mosaic-conf",
      "layout_comp" => "9",
      "layout_auto" => "true"
    })
    |> render_submit()

    view |> form("#create-conference-modal-form") |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-mosaic-conf") |> render_click()
    uid = uid_from_detail(html)

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='edit_conference']")
    |> render_click()

    view |> form("#conference-form", %{"media_video" => "false"}) |> render_change()

    html = view |> form("#conference-form", %{}) |> render_submit()

    assert html =~ ~r/Bascule automatique de mosaïque<\/dt>\s*<dd>\s*oui\s*<\/dd>/
    assert html =~ "/images/layouts/9.svg"
  end

  test "starting then stopping a recording toggles the button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-rec-conf"
    })
    |> render_submit()

    view
    |> form("#create-conference-modal-form")
    |> render_submit()

    html = view |> element("[phx-click=toggle]", "temp-rec-conf") |> render_click()
    uid = uid_from_detail(html)

    assert html =~ "Démarrer l&#39;enregistrement"

    html =
      view
      |> element("button[phx-value-uid='#{uid}'][phx-click='start_recording']")
      |> render_click()

    assert html =~ "Enregistrement en cours"
    assert html =~ "Arrêter l&#39;enregistrement"

    html =
      view
      |> element("button[phx-value-uid='#{uid}'][phx-click='stop_recording']")
      |> render_click()

    assert html =~ "Démarrer l&#39;enregistrement"
  end

  test "a conference list pushed by the poller is reflected without a manual refresh", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/mcu")
    refute html =~ "pushed-conf"

    send(
      view.pid,
      {:kelixip_conferences,
       [
         %{
           uid: "c-pushed",
           name: "pushed-conf",
           domain: "example.com",
           mcu: "ms1",
           layout: %{comp: 1, size: 6, auto: true},
           recording: nil,
           participants: 0
         }
       ]}
    )

    assert render(view) =~ "pushed-conf"
  end

  defp uid_from_detail(html) do
    [_, uid] = Regex.run(~r/UID<\/dt>\s*<dd>([^<]+)<\/dd>/, html)
    uid
  end

  describe "a monitor limited to domains" do
    setup %{conn: conn} do
      %{conn: log_in_admin(conn, :monitor, ["throwaway.local"])}
    end

    test "sees no conference of another domain, not even after a push", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/mcu")

      refute html =~ "standup"

      pushed = [
        %{
          uid: "c-pushed",
          name: "standup",
          domain: "example.com",
          mcu: "ms1",
          participants: 0,
          layout: %{comp: 1},
          recording: nil
        }
      ]

      send(view.pid, {:kelixip_conferences, pushed})
      refute render(view) =~ "standup"
    end

    test "gets no create, destroy or recording button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/mcu")

      refute html =~ "Nouvelle conférence"
      refute html =~ "request_delete_conference"
    end
  end

  describe "an administrator limited to domains" do
    setup %{conn: conn} do
      %{conn: log_in_admin(conn, :admin, ["throwaway.local"])}
    end

    test "refuses a forged destruction outside its reach", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcu")

      log =
        at_info_level(fn ->
          render_submit(view, "confirm_delete_conference", %{"uid" => "c-standup"})
        end)

      refute log =~ "c-standup"
      assert render(view) =~ "hors de votre portée"
    end

    test "refuses a forged creation outside its reach", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcu")

      log =
        at_info_level(fn ->
          render_submit(view, "confirm_create_conference", %{
            "domain" => "example.com",
            "name" => "forgée",
            "max_participants" => "4"
          })
        end)

      refute log =~ "forgée"
      assert render(view) =~ "hors de votre portée"
    end

    test "refuses a forged recording outside its reach", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcu")

      render_click(view, "start_recording", %{"uid" => "c-standup"})

      assert render(view) =~ "hors de votre portée"
    end
  end

  # kelixip logs at :info; test config lowers the level to :warning to keep the
  # suite quiet, so raise it back for the duration of the assertion.
  defp at_info_level(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  test "an account changed elsewhere leaves this page standing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    Phoenix.PubSub.broadcast(
      Kelescope.PubSub,
      Kelescope.Auth.topic(),
      {:account_changed, "quelqun-dautre"}
    )

    assert render(view) =~ "MCU"
  end
end
