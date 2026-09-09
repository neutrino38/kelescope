import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kelescope start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kelescope_core, KelescopeWeb.Endpoint, server: true
end

unless config_env() == :prod do
  config :kelescope_core, KelescopeWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# Authentication (phase 3, ADR-004).
#
# KELESCOPE_AUTH_REAL=1 turns the dev mode off and serves HTTPS with a client
# certificate, the only way to work on the real ceremonies outside production.
# The :prod branch never sets :auth_dev_mode, so a production release cannot
# start without authentication, whatever the environment says.
unless config_env() == :prod do
  config :kelescope_core,
         :auth_dev_mode,
         config_env() == :dev and is_nil(System.get_env("KELESCOPE_AUTH_REAL"))
end

env_hours = fn name, default ->
  String.to_integer(System.get_env(name, to_string(default)))
end

config :kelescope_core, Kelescope.Auth,
  client_cert_days: env_hours.("KELESCOPE_CLIENT_CERT_DAYS", 365),
  session_hours: env_hours.("KELESCOPE_SESSION_HOURS", 12),
  invite_hours: env_hours.("KELESCOPE_INVITE_HOURS", 24)

auth_dir =
  System.get_env("KELESCOPE_AUTH_DIR") ||
    cond do
      config_env() == :prod -> "/var/lib/kelescope/auth"
      config_env() == :dev -> Path.expand("../tmp/auth_dev", __DIR__)
      true -> nil
    end

if auth_dir do
  config :kelescope_core, Kelescope.Auth.Store, dir: auth_dir
end

# Bandit only takes its own keys at the top level: every other TLS option goes
# to Thousand Island's transport.
#
# A connection without a certificate must still reach /enroll, and the verdict
# on the chain belongs to the application, which pins the fingerprint. See
# ADR-004 and Kelescope.Auth.ClientCert.
#
# certificate_authorities: false drops the TLS 1.3 extension of the same name.
# Sent, it makes browsers abort the handshake with a decode_error before any
# request. The cost is a certificate picker that lists every client
# certificate the browser holds instead of only ours.
client_certificate_options = fn dir ->
  [
    verify: :verify_peer,
    fail_if_no_peer_cert: false,
    certificate_authorities: false,
    cacertfile: Path.join(dir, "ca.crt"),
    verify_fun: {&Kelescope.Auth.ClientCert.verify_fun/3, nil}
  ]
end

if config_env() == :dev and System.get_env("KELESCOPE_AUTH_REAL") do
  # PHX_HOST is the WebAuthn relying party identifier: the browser must reach
  # this server by exactly that name, so it also drives the URL here. Point
  # KELESCOPE_SSL_CERTFILE at a certificate valid for that name to work from
  # another machine; the default suits localhost only.
  dev_host = System.get_env("PHX_HOST", "localhost")
  dev_port = String.to_integer(System.get_env("KELESCOPE_HTTPS_PORT", "4001"))

  config :kelescope_core, KelescopeWeb.Endpoint,
    http: false,
    url: [host: dev_host, port: dev_port, scheme: "https"],
    https: [
      port: dev_port,
      cipher_suite: :strong,
      certfile: System.get_env("KELESCOPE_SSL_CERTFILE", "priv/cert/selfsigned.pem"),
      keyfile: System.get_env("KELESCOPE_SSL_KEYFILE", "priv/cert/selfsigned_key.pem"),
      thousand_island_options: [transport_options: client_certificate_options.(auth_dir)]
    ]
end

# KELIXIP_NODE / KELIXIP_COOKIE point at the kelixip instance to monitor,
# same convention as kelictl's RELEASE_NODE. Unset in :dev or :test, the
# link targets this node itself and talks to the local stub instead
# (dev_support/kelix_control_stub.ex) — see docs/architecture/adr-001.
kelixip_node = System.get_env("KELIXIP_NODE")

config :kelescope_core, :kelixip_stub, is_nil(kelixip_node) and config_env() != :prod

config :kelescope_core, Kelescope.Kelixip.Link,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

config :kelescope_monitor, Kelescope.Kelixip.StatusPoller,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

config :kelescope_monitor, Kelescope.Kelixip.AuthDbPoller,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

config :kelescope_core, Kelescope.Kelixip.DomainsLink,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

config :kelescope_mcu, Kelescope.Kelixip.ConferencesPoller,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :kelescope_core, KelescopeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/kelescope_web/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  https_port = String.to_integer(System.get_env("KELESCOPE_HTTPS_PORT", "8443"))

  config :kelescope_core, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  certfile =
    System.get_env("KELESCOPE_SSL_CERTFILE") ||
      raise """
      environment variable KELESCOPE_SSL_CERTFILE is missing.
      It must point to the PEM-encoded certificate (chain) to serve.
      See docs/maintenance/paquet-rpm.md for details.
      """

  keyfile =
    System.get_env("KELESCOPE_SSL_KEYFILE") ||
      raise """
      environment variable KELESCOPE_SSL_KEYFILE is missing.
      It must point to the PEM-encoded private key matching KELESCOPE_SSL_CERTFILE.
      See docs/maintenance/paquet-rpm.md for details.
      """

  config :kelescope_core, KelescopeWeb.Endpoint,
    url: [host: host, port: https_port, scheme: "https"],
    https: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: https_port,
      cipher_suite: :strong,
      certfile: certfile,
      keyfile: keyfile,
      thousand_island_options: [transport_options: client_certificate_options.(auth_dir)]
    ],
    secret_key_base: secret_key_base
end
