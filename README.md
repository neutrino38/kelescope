# kelescope
Web administration interface for [kelixip application server](https://github.com/neutrino38/elixip/blob/master/docs/kelixip/README.md)

## Purpose
- monitor a kelixp instance and later a kelixip cluster
- configure the domains including the scripts, etc

## Phases

### Phase 1 - POC
Monitor liveview: live-refreshing view equivalent to `kelictl monitor`. Read-only, single kelixip instance.

### Phase 2 - monitoring
General kelixip health
Mediaserver pool
Registrations view. Ability to remove an AOR.
DB Connection status
Ability to shutdown a scenario + filters on the monitor view

### Phase 3 - OAUth support
- definition of auth scopes + support for OAuth + predefined support for Google, MS and an Open source alternative
- role definitions
  - general monitor
  - domain monitor
  - general admin
  - domain admin

### Phase 4 - config
Domain config
General config
MCU management

## Design
Admin UI architecture (this app): [kelixip_liveview.md](https://github.com/neutrino38/elixip/blob/release/1.5.1/docs/design/kelixip_liveview.md)

Related, for a different concern (a direct scenario ⟷ LiveView bridge for interactive UIs like a webphone, not the monitoring dashboard): [liveview-adapter.md](https://github.com/neutrino38/elixip/blob/release/1.5.1/docs/design/liveview-adapter.md)

Phase 1 plan: [docs/conception/phase1-monitoring/SPEC.md](docs/conception/phase1-monitoring/SPEC.md), decision record: [docs/architecture/adr-001-connexion-kelixip.md](docs/architecture/adr-001-connexion-kelixip.md).

kelescope IS kelixip_liveview.

## Running

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Then visit [`localhost:4000`](http://localhost:4000).

## Deploying

RPM packaging (self-contained release under `/opt/kelescope`, systemd
service, HTTPS on port 8443): [docs/maintenance/paquet-rpm.md](docs/maintenance/paquet-rpm.md).
