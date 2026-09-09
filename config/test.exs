import Config

# The store is a file, and the supervisor loads it at boot: it has to be wiped
# before the application starts, not from test_helper.exs.
auth_test_dir = Path.expand("../tmp/auth_test", __DIR__)
File.rm_rf!(auth_test_dir)

config :kelescope_core, Kelescope.Auth.Store, dir: auth_test_dir

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kelescope_core, KelescopeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "x27QMwbikzWeLUBnStG6ioW6Ps9YMv3vsSeCxKcfS0skNKWOGQiGLIyJe2kvEqgo",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Every test file that takes the `Kelix.Control` double over kills the pid this
# link monitors as its subscription owner, so it reconnects between files. The
# production five seconds would make each of those waits a five-second one.
config :kelescope_mcu, Kelescope.Kelixip.ConferencesLink, retry_after: 100, poll_interval: 100

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
