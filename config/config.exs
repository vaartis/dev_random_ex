use Mix.Config

#config :logger,
#  level: :warning

config :dev_random_ex,
  token: nil,
  group_id: nil
  # TODO: implement logs properly
  # log_file: "dev_random.log"
config :dev_random_ex, DevRandom.Scheduler,
  jobs: [
    {"*/30 * * * *", {GenServer, :cast, [DevRandom, :post]}}
  ]

config :pid_file, file: "./dev_random_ex.pid"
