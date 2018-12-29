defmodule DevRandom.Scheduler do
  use Quantum.Scheduler, otp_app: :dev_random_ex
end

defmodule DevRandom.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do

    # List all child processes to be supervised
    children = [
      {DevRandom,
       %{
         token: Application.get_env(:dev_random_ex, :token),
         group_id: Application.get_env(:dev_random_ex, :group_id),
         # TODO: implement logs properly
         # log_file: System.get_env("DEVRANDOM_LOG_FILE")
       }
      },
      {DevRandom.Scheduler, []}
    ]

    # Init DETS
    {:ok, _ } = :dets.open_file(RecentImages, [file: 'RecentImages.dets'])

    # Restart every minute for an hour if something goes wrong (e.g. VK starts timing out)
    Supervisor.start_link(children, [strategy: :one_for_one, max_restarts: 60, max_seconds: 60, name: DevRandom.Supervisor])
  end

  def stop(_state) do
    # Close DETS file
    :dets.close(RecentImages)
  end
end
