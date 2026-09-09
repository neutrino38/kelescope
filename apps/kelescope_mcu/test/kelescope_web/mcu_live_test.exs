defmodule KelescopeWeb.McuLiveTest do
  use KelescopeWeb.ConnCase

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  setup %{conn: conn} do
    admin = admin_fixture(:admin, :all)
    await_push!()
    %{conn: log_in(conn, admin), admin: admin}
  end

  # Another test file taking the `Kelix.Control` double over kills the pid the
  # link monitors as its subscription owner. It reconnects on its own timer, and
  # these tests are about what the push does — so they wait for it rather than
  # silently asserting against the polling fallback.
  defp await_push!(tries \\ 200)

  defp await_push!(0), do: raise("ConferencesLink never regained the push contract")

  defp await_push!(tries) do
    case Kelescope.Kelixip.ConferencesLink.snapshot() do
      {_status, :push, _rows} ->
        :ok

      _otherwise ->
        Process.sleep(10)
        await_push!(tries - 1)
    end
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

    # The first sample of a fresh subscription is swept on the spot node-side,
    # but it still arrives as a push rather than in the subscribe reply.
    html = settle(view)
    assert html =~ "audio: ↓"
    assert html =~ "video: ↓"
    assert html =~ "kb/s"
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

    settle(view)

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
          view |> form("#create-conference-modal-form") |> render_submit()
          assert settle(view) =~ "temp-e2e-conf"
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
          view |> form("#delete-conference-modal-form") |> render_submit()
          refute settle(view) =~ "temp-e2e-conf"
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

    settle(view)

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

    html = settle(view)

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

    settle(view)

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

    settle(view)

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

    html = settle(view)

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

    settle(view)

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

    html = settle(view)

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

    settle(view)

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

    html = settle(view)

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

    settle(view)

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

    html = settle(view)

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
    settle(view)

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

    settle(view)

    html = view |> element("[phx-click=toggle]", "temp-rec-conf") |> render_click()
    uid = uid_from_detail(html)

    assert html =~ "Démarrer l&#39;enregistrement"

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='start_recording']")
    |> render_click()

    html = settle(view)
    assert html =~ "Enregistrement en cours"
    assert html =~ "Arrêter l&#39;enregistrement"

    view
    |> element("button[phx-value-uid='#{uid}'][phx-click='stop_recording']")
    |> render_click()

    assert settle(view) =~ "Démarrer l&#39;enregistrement"
  end

  test "a conference created elsewhere appears without any interaction", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/mcu")
    refute html =~ "pushed-conf"

    # Nobody touches the page: the conference is created straight on the node,
    # as another operator or kelictl would.
    {:ok, %{uid: uid}} =
      Kelix.Control.module_command("mcu", "conference.create", %{
        "domain" => "example.com",
        "name" => "pushed-conf"
      })

    assert settle(view) =~ "pushed-conf"

    {:ok, _} = Kelix.Control.module_command("mcu", "conference.delete", %{"uid" => uid})
    refute settle(view) =~ "pushed-conf"
  end

  test "the list has no refresh button while the node pushes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    html = view |> element("[phx-click=toggle]", "standup") |> render_click()

    refute html =~ "refresh_detail"
  end

  test "a roster change pushes the whole roster into the expanded panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")
    uid = create_conference!(view, "temp-roster-conf")

    html = view |> element("[phx-click=toggle]", "temp-roster-conf") |> render_click()
    refute html =~ "sip:dave@example.com"

    :ok =
      Kelix.Control.set_participants(uid, [
        %{
          part_id: 9,
          name: "dave",
          from: "sip:dave@example.com",
          state: :connected,
          medias: [:audio],
          joined_at: ~U[2026-09-09 10:00:00Z]
        }
      ])

    html = settle(view)
    assert html =~ "sip:dave@example.com"
    refute html =~ "Aucun participant."
  end

  test "a leg still ringing is shown as such, with no statistics", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")
    uid = create_conference!(view, "temp-ringing-conf")

    view |> element("[phx-click=toggle]", "temp-ringing-conf") |> render_click()

    :ok =
      Kelix.Control.set_participants(uid, [
        %{
          part_id: nil,
          name: "erin",
          from: "sip:erin@example.com",
          state: :ringing,
          medias: [:audio],
          joined_at: nil
        }
      ])

    assert settle(view) =~ "en sonnerie"
  end

  test "a leg the sweep could not read reads as no answer, and the others still show", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mcu")
    uid = create_conference!(view, "temp-stats-error-conf")

    :ok =
      Kelix.Control.set_participants(uid, [
        %{
          part_id: 1,
          name: "alice",
          from: "sip:alice@stats.test",
          state: :connected,
          medias: [:audio],
          joined_at: ~U[2026-09-09 10:00:00Z]
        },
        %{
          part_id: 2,
          name: "bob",
          from: "sip:bob@stats.test",
          state: :connected,
          medias: [:audio],
          joined_at: ~U[2026-09-09 10:00:00Z]
        }
      ])

    view |> element("[phx-click=toggle]", "temp-stats-error-conf") |> render_click()

    Kelix.Control.push_stats(uid, %{
      at: ~U[2026-09-09 10:00:00Z],
      mcu: "ms1",
      interval_ms: 15_000,
      participants: [
        %{
          part_id: 1,
          name: "alice",
          state: :connected,
          since_ms: 15_000,
          stats: %{},
          stats_error: :timeout
        },
        %{
          part_id: 2,
          name: "bob",
          state: :connected,
          since_ms: 15_000,
          stats: %{
            audio: %{
              receiving: true,
              sending: true,
              num_recv_packets: 4200,
              num_send_packets: 4100,
              total_recv_bytes: 840_000,
              total_send_bytes: 820_000,
              lost_recv_packets: 0,
              recv_kbps: 448,
              send_kbps: 437,
              lost_recv_delta: 0
            }
          },
          stats_error: nil
        }
      ]
    })

    html = settle(view)
    assert html =~ "pas de réponse"
    assert html =~ "audio: ↓4200p"
  end

  test "a sample far older than its own interval is flagged as ageing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")
    uid = create_conference!(view, "temp-ageing-conf")

    :ok =
      Kelix.Control.set_participants(uid, [
        %{
          part_id: 1,
          name: "alice",
          from: "sip:alice@ageing.test",
          state: :connected,
          medias: [:audio],
          joined_at: ~U[2026-09-09 10:00:00Z]
        }
      ])

    view |> element("[phx-click=toggle]", "temp-ageing-conf") |> render_click()

    Kelix.Control.push_stats(uid, %{
      at: ~U[2026-09-09 10:00:00Z],
      mcu: "ms1",
      interval_ms: 15_000,
      participants: [
        %{
          part_id: 1,
          name: "alice",
          state: :connected,
          since_ms: 61_000,
          stats: %{
            audio: %{
              receiving: true,
              sending: true,
              num_recv_packets: 10,
              num_send_packets: 10,
              total_recv_bytes: 100,
              total_send_bytes: 100,
              lost_recv_packets: 0,
              recv_kbps: 1,
              send_kbps: 1,
              lost_recv_delta: 0
            }
          },
          stats_error: nil
        }
      ]
    })

    assert settle(view) =~ "chiffres vieillissants"
  end

  test "applying the same push twice changes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    row = %{
      uid: "c-standup",
      name: "standup",
      domain: "example.com",
      mcu: "ms1",
      layout: %{comp: 1, size: 6, auto: true},
      recording: nil,
      participants: 2
    }

    send(view.pid, {:kelix_conferences, {:upsert, row}})
    once = render(view)
    send(view.pid, {:kelix_conferences, {:upsert, row}})

    assert render(view) == once
  end

  test "a removal naming a conference this page never saw is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")
    before = render(view)

    send(view.pid, {:kelix_conferences, {:remove, "c-never-seen"}})

    assert render(view) == before
  end

  test "a conference snapshot arriving before its list entry is not lost", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("[phx-click=toggle]", "standup") |> render_click()

    # No order holds across topics: the roster may land before the row.
    send(
      view.pid,
      {:kelix_conference, "c-standup",
       {:snapshot,
        %{
          conference: %{
            uid: "c-standup",
            name: "standup",
            domain: "example.com",
            did: "+33970260240",
            mcu: "ms1",
            conf_id: 101,
            vad: 1,
            rate: 32_000,
            medias: [:audio],
            dtmf: true,
            video: %{size: 6, fps: 30, bitrate: 1500, intra_period: 300},
            preferred_video_codec: "H264",
            layout: %{comp: 1, size: 6, auto: true},
            max_participants: 20,
            destroy_when_empty: false,
            persistent: true,
            created_at: ~U[2026-09-01 09:00:00Z],
            stale: false,
            logo: nil,
            recording: nil,
            participants: 1
          },
          participants: [
            %{
              part_id: 42,
              name: "zoe",
              from: "sip:zoe@example.com",
              state: :connected,
              medias: [:audio],
              joined_at: ~U[2026-09-09 11:00:00Z]
            }
          ]
        }}}
    )

    assert render(view) =~ "sip:zoe@example.com"
  end

  test "collapsing a row releases both of its subscriptions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("[phx-click=toggle]", "standup") |> render_click()
    assert held?("c-standup")

    view |> element("[phx-click=toggle]", "standup") |> render_click()
    refute held?("c-standup")
  end

  test "a destroyed conference closes its expanded panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcu")

    view |> element("button", "Nouvelle conférence") |> render_click()

    view
    |> form("form[phx-submit='submit_conference_form']", %{
      "domain" => "example.com",
      "name" => "temp-destroyed-conf"
    })
    |> render_submit()

    view |> form("#create-conference-modal-form") |> render_submit()
    settle(view)

    html = view |> element("[phx-click=toggle]", "temp-destroyed-conf") |> render_click()
    uid = uid_from_detail(html)
    assert held?(uid)

    {:ok, _} = Kelix.Control.module_command("mcu", "conference.delete", %{"uid" => uid})

    html = settle(view)
    refute html =~ "temp-destroyed-conf"
    refute held?(uid)
  end

  # A conference of this test's own, created straight on the node: mutating a
  # shared fixture would decide the outcome of whichever test ExUnit's seed runs
  # next.
  defp create_conference!(view, name) do
    {:ok, %{uid: uid}} =
      Kelix.Control.module_command("mcu", "conference.create", %{
        "domain" => "example.com",
        "name" => name
      })

    # The page learns of it through the list push, not through this call.
    settle(view)
    uid
  end

  # Reads the link's own bookkeeping: the subscriptions the node is still being
  # asked to serve on kelescope's behalf.
  defp held?(uid) do
    holds = :sys.get_state(Kelescope.Kelixip.ConferencesLink).holds
    Map.has_key?(holds, {:conference, uid}) and Map.has_key?(holds, {:stats, uid})
  end

  # Under the push contract an action's effect no longer comes back with the
  # click: it travels kelixip → link → view. Draining the link's mailbox proves
  # its broadcast is out, which puts it ahead of this render in the view's own
  # mailbox — so this waits for the push instead of sleeping on a guess.
  defp settle(view) do
    :sys.get_state(Kelix.Control)
    :sys.get_state(Kelescope.Kelixip.ConferencesLink)
    render(view)
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

      pushed = %{
        uid: "c-pushed",
        name: "standup",
        domain: "example.com",
        mcu: "ms1",
        participants: 0,
        layout: %{comp: 1},
        recording: nil
      }

      send(view.pid, {:kelix_conferences, {:upsert, pushed}})
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
