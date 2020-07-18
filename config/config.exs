use Mix.Config

#config :logger,
#  level: :warning

# https://oauth.vk.com/authorize?client_id=5088888&scope=messages,wall,offline,photos&response_type=token
config :dev_random_ex,
  token: "",
  group_id: 112376753,
  tg_token: "",
  tg_group_id: "@realrandomitt"
  # TODO: implement logs properly
  # log_file: "dev_random.log"
config :dev_random_ex, DevRandom.Scheduler,
  jobs: [
    {"*/30 * * * *", {DevRandom, :post, []}}
  ]

config :dev_random_ex, DevRandom.Mailer,
  adapter: Swoosh.Adapters.Sendmail,
  to: "",
  enabled: false

config :pid_file, file: "./dev_random_ex.pid"
