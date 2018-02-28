defmodule DevRandom.Messages do
  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(args) do
    # Get the long polling data and add it to the data that
    # we got from the parent process (presumably token and group id)

    {:ok, lp_info} = DevRandom.vk_req("messages.getLongPollServer", %{need_pts: 1, lp_version: 2}, args)
    args = Map.put(args, :lp_info, lp_info)

    GenServer.cast(__MODULE__, :lp)

    {:ok, args}
  end

  def handle_cast(:lp, state) do
    %{"server" => server, "key" => key, "ts" => ts} = state.lp_info

    lp_request = HTTPoison.get!(
      "https://#{server}",
      [],
      [
        params: %{
          act: "a_check",
          key: key,
          ts: ts,
          wait: 25,
          mode: 32,
          version: 2
        },
        recv_timeout: 30_000
      ]
    ).body |> Poison.decode!

    state = if Map.has_key?(lp_request, "failed") do
      # In case of an error, update the state variable
      # This will fale if failed == 4, but that shouldn't happen
      case lp_request["failed"] do
        1 -> put_in(state.lp_info["ts"], lp_request["ts"])
        v when v in [2, 3] ->
          {:ok, lp_info} =
            DevRandom.vk_req("messages.getLongPollServer", %{need_pts: 1, lp_version: 2}, state)
          state |>
            put_in([:lp_info, "key"], lp_info["key"]) |>
            put_in([:lp_info, "ts"], lp_info["key"])
      end
    else
      Enum.each(
        lp_request["updates"],
        fn update ->
          if Enum.fetch!(update, 0) == 4 do
            # ID 4 means there's a пnew message, we might as well ignore other updates

            # Sender id is either the user id or the chat id
            [_, message_id, _flags, sender_id, _timestamp, message_text] = update

            if Regex.match?(~r/предложк/iu, message_text) do
              {:ok, sugg_posts} = DevRandom.vk_req(
                "wall.get",
                %{
                  owner_id: -state.group_id,
                  filter: "suggests"
                },
                state
              )

              case DevRandom.vk_req("messages.send", %{peer_id: sender_id, message: sugg_posts["count"]}, state) do
                {:error, %{"error_code" => 7}} ->
                  # Account is probably deleted or messages are blocked
                  {:ok, 1} = DevRandom.vk_req(
                  "messages.markAsRead",
                  %{peer_id: sender_id, start_message_id: message_id},
                  state)
                {:ok, _} -> nil # All good
              end
            end
          end
        end
      )

      # Update the ts and pts fields and return it from the if statement
      state |>
        put_in([:lp_info, "ts"], lp_request["ts"]) |>
        put_in([:lp_info, "pts"], lp_request["pts"])
    end

    GenServer.cast(__MODULE__, :lp)

    {:noreply, state}
  end
end
