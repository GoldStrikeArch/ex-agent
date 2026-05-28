import Config

config :core, :event_log, enabled: config_env() != :test
