defmodule Kelix.Control do
  @moduledoc """
  Stand-in for kelixip's real `Kelix.Control` (see
  docs/conception/phase1-monitoring/SPEC.md) — including
  `subscribe_registrations/2`, `unregister/4` and `shutdown_scenario/2`, so
  kelescope can be built and tested without a live connection to a real
  kelixip node.

  Only compiled for :dev and :test (mix.exs `elixirc_paths`). When
  `KELIXIP_NODE` is unset, `Kelescope.Kelixip.Link` targets `node()` itself,
  so `:rpc.call/4` resolves locally to this module instead of a real remote
  kelixip — letting the LiveView be built and tested before the elixip-side
  patch lands.
  """
  use GenServer
  require Logger

  @fake_status %{
    node: node(),
    uptime_ms: 3_661_000,
    instances: %{active: 2},
    listeners: [
      %{proto: :udp, addr: "0.0.0.0", port: 5060, up: true},
      %{proto: :tls, addr: "0.0.0.0", port: 5061, up: true}
    ],
    media_pool: [
      %{
        name: "ms1",
        module: :mendooze,
        url: "https://10.0.0.5:8443",
        enabled: true,
        healthy: true,
        profiles: %{
          "publicv4" => %{
            available: true,
            announced: "203.0.113.9",
            bind: "10.0.0.5",
            default: true
          },
          "publicv6" => %{available: false, announced: "", bind: "", default: false},
          "internalv4" => %{available: true, announced: "", bind: "10.0.0.5", default: false},
          "internalv6" => %{available: false, announced: "", bind: "", default: false}
        },
        server_status: %{
          "server" => %{"version" => "1.14.0", "uptimeSecs" => 274_353},
          "capabilities" => %{
            "audio" => %{
              "encode" => ["opus", "pcma", "pcmu"],
              "decode" => ["opus", "pcma", "pcmu", "g722"]
            },
            "video" => %{"encode" => ["vp8", "h264"], "decode" => ["vp8", "h264"]}
          },
          "security" => %{"modes" => ["none", "sdes-srtp", "dtls-srtp"]},
          "load" => %{"conferences" => 1}
        }
      },
      %{
        name: "ms2",
        module: :mockup,
        url: "https://10.0.0.6:8443",
        enabled: true,
        healthy: false,
        profiles: :unknown,
        server_status: :unknown
      }
    ],
    modules: [:registrar, :conferencing, :auth_db],
    module_status: %{
      conferencing: %{active_conferences: 1, participants: 3},
      auth_db: %{connected: true}
    },
    domains_version: 3
  }

  @fake_domains [
    %{
      name: "example.com",
      aliases: ["example.org"],
      max_calls: 500,
      functions: [:registrar, :calls],
      registrar: %{script: "registrar.exs", module: "Elixir.Registrar", version: 3, stale: false},
      presence: nil,
      dial_plan: [
        %{
          pattern: "+339.*",
          default: false,
          script: "play.exs",
          module: "Elixir.Play",
          version: 2,
          stale: false
        },
        %{
          pattern: nil,
          default: true,
          script: "fallback.exs",
          module: "Elixir.Fallback",
          version: 1,
          stale: true
        }
      ],
      active_calls: 2,
      registrations: 5
    },
    %{
      name: "test.local",
      aliases: [],
      max_calls: nil,
      functions: [:calls],
      registrar: nil,
      presence: nil,
      dial_plan: [%{pattern: nil, default: true, script: "demo.exs"}],
      active_calls: 0,
      registrations: 0
    },
    %{
      name: "throwaway.local",
      aliases: [],
      max_calls: nil,
      functions: [:calls],
      registrar: nil,
      presence: nil,
      dial_plan: [%{pattern: nil, default: true, script: "demo.exs"}],
      active_calls: 0,
      registrations: 1
    }
  ]

  @fake_registrations %{
    "example.com" => [
      %{
        domain: "example.com",
        aor: "alice",
        contacts: [
          %{
            uri: "sip:alice@10.0.0.9:5060",
            expires_in: 1800,
            source: "udp 10.0.0.9:5060",
            transport: "udp",
            instance: "<urn:uuid:f81d4fae>",
            reg_id: "1",
            methods: nil
          },
          %{
            uri: "sip:alice@10.0.0.12:5061",
            expires_in: 300,
            source: "tls 10.0.0.12:5061",
            transport: "tls",
            instance: nil,
            reg_id: nil,
            methods: nil
          }
        ]
      },
      %{
        domain: "example.com",
        aor: "bob",
        contacts: [
          %{
            uri: "sip:bob@10.0.0.20:5060",
            expires_in: 3600,
            source: "udp 10.0.0.20:5060",
            transport: "udp",
            instance: nil,
            reg_id: nil,
            methods: nil
          }
        ]
      }
    ],
    "test.local" => [],
    "throwaway.local" => [
      %{
        domain: "throwaway.local",
        aor: "carol",
        contacts: [
          %{
            uri: "sip:carol@10.0.0.30:5060",
            expires_in: 1800,
            source: "udp 10.0.0.30:5060",
            transport: "udp",
            instance: nil,
            reg_id: nil,
            methods: nil
          }
        ]
      }
    ]
  }

  # Two conferences dedicated to exercising the MCU screen, isolated from the
  # example.com/test.local/throwaway.local fixtures other tests already use —
  # same rationale as throwaway.local in phase 2. `layout.comp` wire ids follow
  # Kelix.Mod.Mcu.Vocabulary.@mosaics (elixip): 1 = "2x2", 6 = "1+1".
  @fake_conferences [
    %{
      uid: "c-standup",
      name: "standup",
      domain: "example.com",
      did: "+33970260240",
      mcu: "ms1",
      conf_id: 101,
      vad: 1,
      rate: 32_000,
      medias: [:audio, :video, :text],
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
      participants: [
        %{
          part_id: 1,
          name: "alice",
          from: "sip:alice@example.com",
          state: :connected,
          medias: [:audio, :video],
          joined_at: ~U[2026-09-08 09:05:00Z]
        },
        %{
          part_id: 2,
          name: "bob",
          from: "sip:bob@example.com",
          state: :connected,
          medias: [:audio],
          joined_at: ~U[2026-09-08 09:06:00Z]
        }
      ]
    },
    %{
      uid: "c-board",
      name: "board-review",
      domain: "example.com",
      did: "+33970260241",
      mcu: "ms2",
      conf_id: 102,
      vad: 1,
      rate: 8000,
      medias: [:audio, :video],
      dtmf: true,
      video: %{size: 2, fps: 25, bitrate: 512, intra_period: 300},
      preferred_video_codec: nil,
      layout: %{comp: 6, size: 2, auto: true},
      max_participants: 10,
      destroy_when_empty: true,
      persistent: false,
      created_at: ~U[2026-09-08 08:00:00Z],
      stale: false,
      logo: "acme-logo.png",
      recording: %{file: "board-review-20260908.mp4", started_at: ~U[2026-09-08 08:10:00Z]},
      participants: [
        %{
          part_id: 3,
          name: "carol",
          from: "sip:carol@example.com",
          state: :connected,
          medias: [:audio, :video],
          joined_at: ~U[2026-09-08 08:01:00Z]
        }
      ]
    }
  ]

  @fake_rows [
    %{
      id: 1,
      domain: "example.com",
      function: :calls,
      script: "play.exs",
      account: "+33970260233",
      state: "in_call",
      event: "ACK",
      command: "media_play",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    },
    %{
      id: 2,
      domain: "example.com",
      function: :registrar,
      script: "registrar.exs",
      account: "alice",
      state: "registered",
      event: "REGISTER",
      command: "reply 200",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    },
    %{
      id: 3,
      domain: "throwaway.local",
      function: :calls,
      script: "demo.exs",
      account: "throwaway",
      state: "ringing",
      event: "INVITE",
      command: "-",
      medias: "-",
      mediaserver: "-",
      outbound: "-"
    }
  ]

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{
        subs: MapSet.new(),
        counter_subs: MapSet.new(),
        registration_subs: %{},
        rows: @fake_rows,
        status: @fake_status,
        domains: @fake_domains,
        registrations: @fake_registrations,
        conferences: @fake_conferences
      },
      name: __MODULE__
    )
  end

  def subscribe_monitor(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def status(), do: GenServer.call(__MODULE__, :status)

  def domains(), do: GenServer.call(__MODULE__, :domains)

  def domain(name), do: GenServer.call(__MODULE__, {:domain, name})

  def subscribe_domain_counters(pid), do: GenServer.call(__MODULE__, {:subscribe_counters, pid})

  def subscribe_registrations(pid, domain),
    do: GenServer.call(__MODULE__, {:subscribe_registrations, pid, domain})

  @doc "Unregisters one contact from an AOR; logged and pushed to registration subscribers."
  def unregister(domain, aor, contact_uri, admin),
    do: GenServer.call(__MODULE__, {:unregister, domain, aor, contact_uri, admin})

  @doc "Shuts down a running scenario instance; logged and pushed to monitor subscribers."
  def shutdown_scenario(id, admin),
    do: GenServer.call(__MODULE__, {:shutdown_scenario, id, admin})

  @doc "Reloads `names`; `fallback.exs` always fails, to exercise the error path."
  def reload_script(names, _notify? \\ false),
    do: GenServer.call(__MODULE__, {:reload_script, names})

  @doc "Stand-in for `Kelix.Control.module_command/3` (`kelictl <module> <cmd> <args>`)."
  def module_command(module, cmd, args),
    do: GenServer.call(__MODULE__, {:module_command, module, cmd, args})

  @doc "Pushes `msg` to every scenario subscriber right away, bypassing the random tick (used by tests)."
  def push(msg), do: GenServer.cast(__MODULE__, {:push, msg})

  @doc "Pushes a `{:kelix_domain_counter, domain, kind, count}` to every counter subscriber (used by tests)."
  def push_counter(msg), do: GenServer.cast(__MODULE__, {:push_counter, msg})

  @doc "Replaces the status `status/0` returns next (used by tests)."
  def set_status(status), do: GenServer.cast(__MODULE__, {:set_status, status})

  @doc "Pushes a `{:kelix_registrations, domain, msg}` to that domain's subscribers (used by tests)."
  def push_registration(domain, msg),
    do: GenServer.cast(__MODULE__, {:push_registration, domain, msg})

  @impl true
  def init(state) do
    :timer.send_interval(3_000, :tick)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, state.rows, %{state | subs: MapSet.put(state.subs, pid)}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:domains, _from, state) do
    {:reply, state.domains, state}
  end

  @impl true
  def handle_call({:domain, name}, _from, state) do
    reply = if d = find_domain(state, name), do: {:ok, d}, else: {:error, :not_found}
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:subscribe_counters, pid}, _from, state) do
    {:reply, state.domains, %{state | counter_subs: MapSet.put(state.counter_subs, pid)}}
  end

  @impl true
  def handle_call({:subscribe_registrations, pid, name}, _from, state) do
    case find_domain(state, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      d ->
        regs = Map.get(state.registrations, d.name, [])

        subs =
          Map.update(state.registration_subs, d.name, MapSet.new([pid]), &MapSet.put(&1, pid))

        {:reply, {:ok, %{domain: d.name, registrations: regs}},
         %{state | registration_subs: subs}}
    end
  end

  @impl true
  def handle_call({:unregister, name, aor, contact_uri, admin}, _from, state) do
    with d when not is_nil(d) <- find_domain(state, name),
         registration when not is_nil(registration) <-
           Enum.find(Map.get(state.registrations, d.name, []), &(&1.aor == aor)),
         true <- Enum.any?(registration.contacts, &(&1.uri == contact_uri)) do
      Logger.info(
        "registration contact removed by admin=#{admin} domain=#{d.name} aor=#{aor} uri=#{contact_uri}"
      )

      regs = Map.get(state.registrations, d.name, [])
      remaining = Enum.reject(registration.contacts, &(&1.uri == contact_uri))

      {updated_regs, push} =
        if remaining == [] do
          {Enum.reject(regs, &(&1.aor == aor)), {:remove, aor}}
        else
          updated = %{registration | contacts: remaining}
          {Enum.map(regs, &if(&1.aor == aor, do: updated, else: &1)), {:upsert, updated}}
        end

      for pid <- Map.get(state.registration_subs, d.name, MapSet.new()),
          do: send(pid, {:kelix_registrations, d.name, push})

      new_state = %{state | registrations: Map.put(state.registrations, d.name, updated_regs)}
      {:reply, :ok, new_state}
    else
      # matches the real `Kelix.Control.unregister/3,4` contract: a bare
      # `:notfound` atom, not an `{:error, _}` tuple.
      _ -> {:reply, :notfound, state}
    end
  end

  @impl true
  def handle_call({:shutdown_scenario, id, admin}, _from, state) do
    case Enum.find(state.rows, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      row ->
        Logger.info("scenario #{id} (#{row.account}@#{row.domain}) shut down by admin=#{admin}")

        for pid <- state.subs, do: send(pid, {:kelix_monitor, {:remove, id}})

        {:reply, :ok, %{state | rows: Enum.reject(state.rows, &(&1.id == id))}}
    end
  end

  @impl true
  def handle_call({:reload_script, names}, _from, state) do
    reply =
      Map.new(names, fn
        "fallback.exs" -> {"fallback.exs", {:error, :compile_error}}
        name -> {name, :ok}
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:module_command, "mcu", cmd, args}, _from, state) do
    {reply, state} = mcu_command(cmd, args, state)
    {:reply, reply, state}
  end

  def handle_call({:module_command, _module, _cmd, _args}, _from, state) do
    {:reply, {:error, :unknown_module}, state}
  end

  @impl true
  def handle_cast({:push, msg}, state) do
    for pid <- state.subs, do: send(pid, msg)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:push_counter, msg}, state) do
    for pid <- state.counter_subs, do: send(pid, msg)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_status, status}, state) do
    {:noreply, %{state | status: status}}
  end

  @impl true
  def handle_cast({:push_registration, domain, msg}, state) do
    for pid <- Map.get(state.registration_subs, domain, MapSet.new()),
        do: send(pid, {:kelix_registrations, domain, msg})

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    row = state.rows |> Enum.random() |> Map.put(:event, Enum.random(~w(ACK BYE INFO REGISTER)))

    for pid <- state.subs, do: send(pid, {:kelix_monitor, {:upsert, row}})

    {:noreply, state}
  end

  defp find_domain(state, name) do
    down = String.downcase(name)

    Enum.find(state.domains, fn d ->
      String.downcase(d.name) == down or down in Enum.map(d.aliases, &String.downcase/1)
    end)
  end

  # ── mcu module_command dispatch ──────────────────────────────────────────
  # Mirrors Kelix.Mod.Mcu.do_control/2 (elixip apps/kelix_modules), including its
  # "admin" tracing on create/delete (see mcu.ex's do_control("conference.create"/
  # "conference.delete", ...)).

  defp mcu_command("conference.list", args, state) do
    domain = Map.get(args, "domain")
    did = Map.get(args, "did")

    rows =
      state.conferences
      |> Enum.filter(&(is_nil(domain) or &1.domain == domain))
      |> Enum.filter(&(is_nil(did) or &1.did == did))
      |> Enum.map(&render_conference/1)

    {{:ok, rows}, state}
  end

  defp mcu_command("conference.show", args, state) do
    case find_conference(state, Map.get(args, "uid")) do
      nil ->
        {{:error, :not_found}, state}

      conf ->
        reply =
          conf
          |> render_conference()
          |> Map.put(:participants, Enum.map(conf.participants, &render_participant/1))

        {{:ok, reply}, state}
    end
  end

  defp mcu_command("conference.create", args, state) do
    admin = Map.get(args, "admin")

    result =
      case Map.get(args, "domain") do
        nil ->
          {:error, "domain is required"}

        domain ->
          video = video_from_args(args, %{size: 6, fps: 30, bitrate: 1500, intra_period: 300})

          layout =
            align_layout_size(layout_from_args(args, %{comp: 1, size: 6, auto: true}), video)

          {:ok,
           %{
             uid: "c-" <> Integer.to_string(System.unique_integer([:positive])),
             name: Map.get(args, "name") || "conf-#{length(state.conferences) + 1}",
             domain: domain,
             did: Map.get(args, "did") || "+339702602#{50 + length(state.conferences)}",
             mcu: Map.get(args, "mcu") || "ms1",
             conf_id: System.unique_integer([:positive, :monotonic]),
             vad: Map.get(args, "vad") || 1,
             rate: Map.get(args, "rate") || 32_000,
             medias: medias_from_args(args) || [:audio, :video, :text],
             dtmf: true,
             video: video,
             preferred_video_codec: preferred_video_codec_from_args(args, nil),
             layout: layout,
             max_participants: Map.get(args, "max_participants") || 20,
             destroy_when_empty: Map.get(args, "destroy_when_empty") || false,
             persistent: true,
             created_at: DateTime.utc_now(),
             stale: false,
             logo: Map.get(args, "logo"),
             recording: nil,
             participants: []
           }}
      end

    Logger.info(
      "mcu conference.create domain=#{Map.get(args, "domain")} by admin=#{admin || "unknown"}: " <>
        "#{inspect(result)}"
    )

    case result do
      {:ok, conf} ->
        {{:ok, %{uid: conf.uid, did: conf.did, conf_id: conf.conf_id, mcu: conf.mcu}},
         %{state | conferences: state.conferences ++ [conf]}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp mcu_command("conference.update", args, state) do
    case find_conference(state, Map.get(args, "uid")) do
      nil ->
        {{:error, :not_found}, state}

      conf ->
        video = video_from_args(args, conf.video)
        layout = align_layout_size(layout_from_args(args, conf.layout), video)

        updated =
          conf
          |> maybe_put(:name, Map.get(args, "name"))
          |> maybe_put(:max_participants, Map.get(args, "max_participants"))
          |> maybe_put(:destroy_when_empty, Map.get(args, "destroy_when_empty"))
          |> maybe_put(:vad, Map.get(args, "vad"))
          |> maybe_put(:rate, Map.get(args, "rate"))
          |> maybe_put(:medias, medias_from_args(args))
          |> maybe_put(:logo, Map.get(args, "logo"))
          |> Map.put(:layout, layout)
          |> Map.put(:video, video)
          |> Map.put(
            :preferred_video_codec,
            preferred_video_codec_from_args(args, conf.preferred_video_codec)
          )

        {{:ok, render_conference(updated)},
         %{state | conferences: replace_conference(state.conferences, updated)}}
    end
  end

  defp mcu_command("conference.delete", args, state) do
    uid = Map.get(args, "uid")
    admin = Map.get(args, "admin")
    force = Map.get(args, "force", false)

    result =
      case find_conference(state, uid) do
        nil -> {:error, :not_found}
        %{participants: []} -> :ok
        _conf when force -> :ok
        _conf -> {:error, :not_empty}
      end

    Logger.info(
      "mcu conference.delete uid=#{uid} by admin=#{admin || "unknown"}: #{inspect(result)}"
    )

    case result do
      :ok ->
        {{:ok, %{}}, %{state | conferences: Enum.reject(state.conferences, &(&1.uid == uid))}}

      error ->
        {error, state}
    end
  end

  defp mcu_command("recording.start", args, state) do
    uid = Map.get(args, "uid")

    case find_conference(state, uid) do
      nil ->
        {{:error, :not_found}, state}

      %{recording: recording} when not is_nil(recording) ->
        {{:error, :already_recording}, state}

      conf ->
        file =
          Map.get(args, "file") ||
            "#{conf.uid}-#{DateTime.to_unix(DateTime.utc_now())}.mp4"

        updated = %{conf | recording: %{file: file, started_at: DateTime.utc_now()}}

        {{:ok, %{uid: uid, file: file, path: file, mcu: conf.mcu}},
         %{state | conferences: replace_conference(state.conferences, updated)}}
    end
  end

  defp mcu_command("recording.stop", args, state) do
    uid = Map.get(args, "uid")

    case find_conference(state, uid) do
      nil ->
        {{:error, :not_found}, state}

      %{recording: nil} ->
        {{:error, :not_recording}, state}

      conf ->
        updated = %{conf | recording: nil}

        {{:ok, %{uid: uid, file: conf.recording.file}},
         %{state | conferences: replace_conference(state.conferences, updated)}}
    end
  end

  defp mcu_command("participant.show", args, state) do
    with conf when not is_nil(conf) <- find_conference(state, Map.get(args, "uid")),
         part when not is_nil(part) <- find_participant(conf, Map.get(args, "part_id")) do
      reply = Map.put(render_participant(part), :stats, fake_statistics(part))
      {{:ok, reply}, state}
    else
      _ -> {{:error, :not_found}, state}
    end
  end

  defp mcu_command(_cmd, _args, state), do: {{:error, :unknown_command}, state}

  defp find_conference(state, uid), do: Enum.find(state.conferences, &(&1.uid == uid))

  defp find_participant(conf, part_id) do
    Enum.find(conf.participants, &(&1.part_id == coerce_part_id(part_id)))
  end

  defp coerce_part_id(id) when is_integer(id), do: id
  defp coerce_part_id(id) when is_binary(id), do: String.to_integer(id)

  defp replace_conference(conferences, updated),
    do: Enum.map(conferences, &if(&1.uid == updated.uid, do: updated, else: &1))

  defp render_conference(conf) do
    conf
    |> Map.put(:participants, length(conf.participants))
    |> Map.update!(:recording, &(&1 && &1.file))
  end

  defp render_participant(p),
    do: Map.take(p, [:part_id, :name, :from, :state, :medias, :joined_at])

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp layout_from_args(args, default) do
    case Map.get(args, "layout") do
      nil ->
        default

      given ->
        default
        |> maybe_put_layout_field(given, "comp", :comp)
        |> maybe_put_layout_field(given, "auto", :auto)
    end
  end

  defp maybe_put_layout_field(layout, given, string_key, atom_key) do
    case Map.get(given, string_key) do
      nil -> layout
      value -> Map.put(layout, atom_key, value)
    end
  end

  # The mosaic canvas is the encoded picture: naming a `video.size` moves the
  # layout's canvas size with it, same invariant as elixip's `align_sizes/4`
  # (`Kelix.Mod.Mcu`) — kelescope only ever names the size through `video`.
  defp align_layout_size(layout, video), do: %{layout | size: video.size}

  # `video` is merged field-by-field over the current values, like `layout` —
  # naming just `size` leaves `fps`/`bitrate`/`intra_period` untouched.
  defp video_from_args(args, default) do
    case Map.get(args, "video") do
      nil ->
        default

      given ->
        default
        |> maybe_put_video_field(given, "size", :size)
        |> maybe_put_video_field(given, "fps", :fps)
        |> maybe_put_video_field(given, "bitrate", :bitrate)
        |> maybe_put_video_field(given, "intra_period", :intra_period)
    end
  end

  defp maybe_put_video_field(video, given, string_key, atom_key) do
    case Map.get(given, string_key) do
      nil -> video
      value -> Map.put(video, atom_key, value)
    end
  end

  # Absent key: keep the current preference. Present, even "": an explicit choice —
  # "" (the form's "aucune préférence" option) clears it, same as the real
  # `Vocabulary.video_codec/2` treating "" and "none" alike.
  defp preferred_video_codec_from_args(args, current) do
    case Map.fetch(args, "preferred_video_codec") do
      :error -> current
      {:ok, v} when v in [nil, ""] -> nil
      {:ok, v} -> v
    end
  end

  # `nil` when absent — kelescope never sends an empty list (mirrors elixip
  # refusing "a conference that answers nothing"), so `maybe_put`/`||` above
  # read absence as "leave as configured", never as "clear the medias".
  defp medias_from_args(args) do
    case Map.get(args, "medias") do
      nil -> nil
      names -> Enum.map(names, &String.to_existing_atom/1)
    end
  end

  # Deterministic-looking fake numbers (from `part_id`), one entry per media the
  # participant carries — same shape as `Kelix.Mod.Mcu.decode_statistics/1` (elixip).
  defp fake_statistics(part) do
    for media <- part.medias, into: %{} do
      base = part.part_id * 1000 + media_offset(media)

      {media,
       %{
         receiving: true,
         sending: true,
         lost_recv_packets: rem(base, 5),
         num_recv_packets: base + 40_000,
         num_send_packets: base + 38_000,
         total_recv_bytes: (base + 40_000) * 200,
         total_send_bytes: (base + 38_000) * 200
       }}
    end
  end

  defp media_offset(:audio), do: 1
  defp media_offset(:video), do: 2
  defp media_offset(:text), do: 3
  defp media_offset(_), do: 0
end
