defmodule DevRandom.Messages do
  use GenServer

  alias DevRandom.Platforms.Post
  alias DevRandom.Platforms.Telegram.PostAttachment

  import DevRandom, only: [tg_req: 2]

  def start_link(_state) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    GenServer.cast(__MODULE__, :check_updates)

    {:ok, state}
  end

  def handle_cast(:check_updates, state) do
    req_params =
      (
        pars = %{timeout: 60 * 5, allowed_updates: ["message"]}

        maybe_next_update_id = state[:next_update_id]
        # Put an offset in if it came from a previous run
        if maybe_next_update_id, do: Map.put(pars, :offset, maybe_next_update_id), else: pars
      )

    %{"ok" => true, "result" => updates} = tg_req("getUpdates", req_params)

    for update <- updates do
      with %{"message" => message, "update_id" => update_id} <- update,
           %{
             "chat" => %{"type" => "private"},
             "from" => %{"id" => user_id, "first_name" => fname},
             "message_id" => msg_id
           } <- message do
        {type, attachment_file_id} =
          case message do
            %{"photo" => photo_sizes} ->
              {:photo, List.last(photo_sizes) |> Map.get("file_id")}

            %{"animation" => %{"file_id" => file_id}} ->
              {:animation, file_id}

            _ ->
              {nil, nil}
          end

        # If the attachments are those allowed
        if type && attachment_file_id do
          anon_regex = ~r/^anon/i

          is_anon =
            if message["caption"], do: String.match?(message["caption"], anon_regex), else: false

          from_str =
            if not is_anon do
              "from [#{fname}](tg://user?id=#{user_id})\n"
            else
              ""
            end

          caption =
            if(message["caption"],
              do: from_str <> String.replace(message["caption"], anon_regex, ""),
              else: from_str
            )
            |> String.trim()

          # update_id is used as a key because it's unique-ish
          :dets.insert(
            BotReceivedImages,
            {
              update_id,
              %Post{
                attachments: [
                  %PostAttachment{
                    file_id: attachment_file_id,
                    type: type
                  }
                ],
                text: caption
              }
            }
          )

          size =
            (
              info = :dets.info(BotReceivedImages)

              {:size, size} = List.keyfind(info, :size, 0)

              size
            )

          post_or_posts = if size == 1, do: "post", else: "posts"

          if size > 0 do
            tg_req("sendMessage", %{
              chat_id: user_id,
              reply_to_message_id: msg_id,
              text: "There are now #{size} #{post_or_posts} in queue"
            })
          end
        end
      end
    end

    GenServer.cast(__MODULE__, :check_updates)

    state =
      if not Enum.empty?(updates) do
        last_update_id = List.last(updates) |> Map.get("update_id")

        state |> Map.put(:next_update_id, last_update_id + 1)
      else
        state
      end

    {:noreply, state}
  end
end
