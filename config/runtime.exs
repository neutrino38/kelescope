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
  config :kelescope, KelescopeWeb.Endpoint, server: true
end

unless config_env() == :prod do
  config :kelescope, KelescopeWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# KELIXIP_NODE / KELIXIP_COOKIE point at the kelixip instance to monitor,
# same convention as kelictl's RELEASE_NODE. Unset in :dev or :test, the
# link targets this node itself and talks to the local stub instead
# (dev_support/kelix_control_stub.ex) — see docs/architecture/adr-001.
kelixip_node = System.get_env("KELIXIP_NODE")

config :kelescope, :kelixip_stub, is_nil(kelixip_node) and config_env() != :prod

config :kelescope, Kelescope.Kelixip.Link,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

config :kelescope, Kelescope.Kelixip.StatusPoller,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

config :kelescope, Kelescope.Kelixip.DomainsLink,
  node: (kelixip_node || to_string(node())) |> String.to_atom(),
  cookie: System.get_env("KELIXIP_COOKIE")

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :kelescope, KelescopeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/kelescope_web/router\.ex$",
        ~r"lib/kelescope_web/(controllers|live|components)/.*\.(ex|heex)$"
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

  config :kelescope, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

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

  config :kelescope, KelescopeWeb.Endpoint,
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
      keyfile: keyfile
    ],
    secret_key_base: secret_key_base
end
