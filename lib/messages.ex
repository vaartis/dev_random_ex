defmodule DevRandom.Messages do
  use GenServer

  alias DevRandom.Platforms.Attachment
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
      with %{"message" => message} <- update,
           %{
             "chat" => %{"type" => "private"},
             "from" => %{"id" => user_id, "first_name" => fname},
             "message_id" => msg_id
           } <- message do
        {actionType, actionData} =
          case message do
            %{"photo" => photo_sizes} ->
              {:queue, {:photo, List.last(photo_sizes) |> Map.get("file_id")}}

            %{"animation" => %{"file_id" => file_id}} ->
              {:queue, {:animation, file_id}}

            %{
              "reply_to_message" => reply_msg,
              "text" => text,
              "entities" => [%{"type" => "bot_command", "offset" => offset, "length" => length}]
            } ->
              command = String.slice(text, offset, length)

              case command do
                "/cancel" ->
                  {:cancel, reply_msg["message_id"]}

                _ ->
                  {:error, "Unknown command #{command}"}
              end

            _ ->
              {nil, nil}
          end

        case {actionType, actionData} do
          {:queue, {type, attachment_file_id}} ->
            anon_regex = ~r/^anon/i

            is_anon =
              if message["caption"],
                do: String.match?(message["caption"], anon_regex),
                else: false

            source_link =
              if not is_anon,
                do: {:telegram, fname, user_id},
                else: nil

            caption =
              if(message["caption"],
                do: String.replace(message["caption"], anon_regex, ""),
                else: ""
              )
              |> String.trim()

            attachment = %PostAttachment{
              file_id: attachment_file_id,
              type: type
            }

            used_recently_msg =
              (
                hash = Attachment.phash(attachment)

                lookup_result = DevRandom.image_recent_lookup(hash)

                if not Enum.empty?(lookup_result) do
                  [{_, %{last_used: last_used, next_use_allowed_in: next_use_allowed_in}}] =
                    lookup_result

                  if Timex.today() in Timex.Interval.new(
                       from: last_used,
                       until: [days: next_use_allowed_in]
                     ) do
                    next_allowed_date = Date.add(last_used, next_use_allowed_in)

                    "The image was already posted recently.\n" <>
                      "Last post date: #{last_used}, next allowed post date: #{next_allowed_date}"
                  end
                end
              )

            # Only add the image if it wasn't used recently
            if !used_recently_msg do
              post = %Post{
                attachments: [attachment],
                text: caption,
                source_link: source_link
              }

              # Use a combination of user and message id to help lookup and keep it unique
              :dets.insert(
                BotReceivedImages,
                {
                  {user_id, msg_id},
                  post
                }
              )

              size =
                (
                  info = :dets.info(BotReceivedImages)

                  {:size, size} = List.keyfind(info, :size, 0)

                  size
                )

              {are_or_is, post_or_posts} =
                if size == 1, do: {"is", "post"}, else: {"are", "posts"}

              if size > 0 do
                tg_req("sendMessage", %{
                  chat_id: user_id,
                  reply_to_message_id: msg_id,
                  text: "There #{are_or_is} now #{size} #{post_or_posts} in the queue"
                })
              end
            else
              # Otherwise inform that it was
              tg_req("sendMessage", %{
                chat_id: user_id,
                reply_to_message_id: msg_id,
                text: used_recently_msg
              })
            end

          {:cancel, cancel_msg_id} ->
            # If the message is still in queue, remove it
            reply_text =
              if :dets.member(BotReceivedImages, {user_id, cancel_msg_id}) do
                :dets.delete(BotReceivedImages, {user_id, cancel_msg_id})

                "Canceled the post"
              else
                "The post wasn't in queue or was already posted"
              end

            tg_req("sendMessage", %{
              chat_id: user_id,
              reply_to_message_id: msg_id,
              text: reply_text
            })

          {:error, error_msg} ->
            tg_req("sendMessage", %{
              chat_id: user_id,
              reply_to_message_id: msg_id,
              text: error_msg
            })

          {nil, nil} ->
            nil
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
