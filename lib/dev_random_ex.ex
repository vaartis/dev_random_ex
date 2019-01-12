defmodule DevRandom do
  require Logger

  use GenServer

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks

  @spec init(args :: map) :: {atom, map}
  def init(%{token: token, group_id: group_id} = args) when token != nil and group_id != nil do

    msgs_child = [
      {DevRandom.Platforms.VK.RequestTimeAgent, []},
      # {DevRandom.Messages, args}
    ]
    Supervisor.start_link(msgs_child, [strategy: :one_for_one, name: DevRandom.UtilsSupervisor])

    {
      :ok,
      args
    }
  end

  def handle_cast(:post, state) do
    tg_group_id = Application.get_env(:dev_random_ex, :tg_group_id)

    post_or_posts = DevRandom.Platforms.VK.random_post_or_posts()

    case post_or_posts do
      {:suggested, post} ->
        text = post["text"]
        text_msg_id = if text != "" do
          %{"ok" => true, "result" => %{"message_id" => text_msg_id}} = tg_req("sendMessage", %{chat_id: tg_group_id, text: text})
          text_msg_id
        end

        filtered_atts = post["attachments"]
        |> Enum.filter(fn att -> att["type"] in ["photo", "doc"] end)
        |> Enum.reject(fn att -> att["doc"]["type"] in [5, 6] end) # Discard audio/video

        # If there's at least one new image, use everything and post it
        if maybe_use_attachments(filtered_atts) do
          Enum.each(filtered_atts,
            fn %{"photo" => photo, "type" => "photo"} ->
              biggest =
                Enum.find_value(
                  ["photo_2560", "photo_1280", "photo_807", "photo_604", "photo_130", "photo_75"],
                  fn size -> photo[size] end
                ) # Should return the biggest size. nil is not a thruthy value, therefore the find function will ignore it
              tg_req("sendPhoto", %{chat_id: tg_group_id, photo: biggest, reply_to_message_id: text_msg_id})

              # Mark image as used
              image_hash = :crypto.hash(:md5, HTTPoison.get!(photo["photo_75"]).body)
              use_image(image_hash)

              %{"doc" => doc, "type" => "doc"} ->
                case doc["type"] do
                  3 ->  # GIF
                    tg_req("sendAnimation", %{chat_id: tg_group_id, animation: doc["url"], reply_to_message_id: text_msg_id})
                  4 -> # Image
                    tg_req("sendPhoto", %{chat_id: tg_group_id, photo: doc["url"], reply_to_message_id: text_msg_id})
                  _ ->
                    tg_req("sendDocument", %{chat_id: tg_group_id, document: doc["url"], reply_to_message_id: text_msg_id})
                end
            end
          )

          # Delete the post
          DevRandom.Platforms.VK.delete_suggested_post(post["id"])
        else
          handle_cast(:post, state) # Restart
        end
      {:saved, image} ->
        image_hash = :crypto.hash(:md5, HTTPoison.get!(image["photo_75"]).body)
        if not image_used_recently?(image_hash) do
          biggest =
            Enum.find_value(
              ["photo_2560", "photo_1280", "photo_807", "photo_604", "photo_130", "photo_75"],
              fn size -> image[size] end
            ) # Should return the biggest size. nil is not a thruthy value, therefore the find function will ignore it
          tg_req("sendPhoto", %{chat_id: tg_group_id, photo: biggest, caption: "[Source](https://vk.com/photo#{image["owner_id"]}_#{image["id"]})", parse_mode: "Markdown"})
        else
          # Restart
          handle_cast(:post, state)
        end
    end

    {:noreply, state}
  end

  def tg_req(method_name, params) do
    tg_token = Application.get_env(:dev_random_ex, :tg_token)

    query_result = HTTPoison.get!(
      "https://api.telegram.org/bot#{tg_token}/#{method_name}",
      [],
      [params: params]
    )

    Poison.decode! query_result.body
  end

  def maybe_use_attachments(attachments) do
    attachment_hashes = attachments |>
      Enum.filter(&(&1["type"] in ["doc", "photo"])) |>
      Enum.map(fn a ->
        case a["type"] do
          "photo" -> :crypto.hash(:md5, HTTPoison.get!(a["photo"]["photo_75"]).body)
          "doc" -> :crypto.hash(:md5, HTTPoison.get!(a["doc"]["url"]).body)
        end
      end)

    if Enum.all?(attachment_hashes, &image_used_recently?/1) do
      false
    else
      Enum.each(attachment_hashes, &use_image/1)
      true
    end
  end

  @doc """
  Checks if the image was used recently
  """
  def image_used_recently?(image_hash) do
    use Timex

    lookup_result = :dets.lookup(RecentImages, image_hash)

    if Enum.empty?(lookup_result) do
      # The image was not used at all
      false
    else
      {^image_hash, %{last_used: date, next_use_allowed_in: next_use_allowed_in}} = List.first(lookup_result)

      # Image was posted withing the next allowed use interval
      Timex.today in Timex.Interval.new(from: date, until: [days: next_use_allowed_in])
    end
  end

  @doc """
  Mark image as used in DETS.
  """
  def use_image(image_hash) do
    lookup_result = :dets.lookup(RecentImages, image_hash)

    if Enum.empty?(lookup_result) do
      # Let it be two weeks for starters
      :dets.insert(RecentImages, {image_hash, %{last_used: Timex.today, next_use_allowed_in: 14}})
    else
      # Get the last use
      {^image_hash, %{next_use_allowed_in: next_use_allowed_in}} = List.first(lookup_result)

      # Make the next allowed use time twice as long
      :dets.insert(RecentImages, {image_hash, %{last_used: Timex.today, next_use_allowed_in: next_use_allowed_in * 2}})
    end
  end
end
