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
Domain list an detials
Mediaserver pool
Registrations view. Ability to remove an AOR.
DB Connection status
Ability to shutdown a scenario + filters on the monitor view

### Phase 3 - Authentication and roles
- roles: general monitor, domain monitor, general admin, domain admin
- authentication by passkey (WebAuthn) plus a client certificate issued by kelescope, both required
- general administrators create accounts by invitation, reset and revoke access
- dev mode without certificate, acting as a general admin

Decision record: [docs/architecture/adr-004-authentification-passkey-certificat.md](docs/architecture/adr-004-authentification-passkey-certificat.md), plan: [docs/conception/phase3-auth/SPEC.md](docs/conception/phase3-auth/SPEC.md).

Enrolling a workstation (French): [docs/utilisation/enrolement.md](docs/utilisation/enrolement.md).

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

Authentication is off in dev: the app behaves as if a general admin were
logged in. To work on the real ceremonies, generate a self-signed certificate
once with `mix phx.gen.cert`, then:

```
mix run -e 'Kelescope.Auth.bootstrap("dev")'   # service stopped, prints an invitation code
KELESCOPE_AUTH_REAL=1 mix phx.server           # HTTPS on 4001, mTLS on
```

Then enrol at [`https://localhost:4001/enroll`](https://localhost:4001/enroll).
The dev account store lives in `tmp/auth_dev/`.

From another machine, the browser must reach the server by the exact name
WebAuthn is bound to, and that name must match the served certificate:

```
PHX_HOST=host.example.org \
KELESCOPE_SSL_CERTFILE=/etc/ssl/host.example.org/fullchain.pem \
KELESCOPE_SSL_KEYFILE=/etc/ssl/host.example.org/privkey.pem \
KELESCOPE_AUTH_REAL=1 mix phx.server
```

`KELESCOPE_HTTPS_PORT` moves the port away from 4001.

## Testing

* Run `mix test` to run the test suite

## Deploying

RPM packaging (self-contained release under `/opt/kelescope`, systemd
service, HTTPS on port 8443): [docs/maintenance/paquet-rpm.md](docs/maintenance/paquet-rpm.md).
