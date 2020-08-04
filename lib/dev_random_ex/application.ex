defmodule DevRandom.Scheduler do
  use Quantum, otp_app: :dev_random_ex
end

defmodule DevRandom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {DevRandom,
       %{
         token: Application.get_env(:dev_random_ex, :token),
         group_id: Application.get_env(:dev_random_ex, :group_id)
         # TODO: implement logs properly
         # log_file: System.get_env("DEVRANDOM_LOG_FILE")
       }},
      DevRandom.Scheduler
    ]

    # Init DETS
    {:ok, _} = :dets.open_file(RecentImages, file: 'RecentImages.dets')

    # Migration from simple number hashes to tuple of type and hash
    # to_migrate =
    #   :dets.select(
    #     RecentImages,
    #     [{{:"$1", :"$2"}, [{:is_integer, :"$1"}], [:"$_"]}]
    #   )
    #
    # :dets.insert(
    #   RecentImages,
    #   Enum.map(to_migrate, fn {hash, data} ->
    #     {{:phash, hash}, data}
    #   end)
    # )
    #
    # Enum.each(
    #   to_migrate,
    #   fn {hash, _} ->
    #     :dets.delete(RecentImages, hash)
    #   end
    # )

    {:ok, _} = :dets.open_file(BotReceivedImages, file: 'BotReceivedImages.dets')

    # Restart every minute for an hour if something goes wrong (e.g. VK starts timing out)
    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 60,
      max_seconds: 60,
      name: DevRandom.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    # Close DETS file
    :dets.close(RecentImages)
    :dets.close(BotReceivedImages)
  end
end
