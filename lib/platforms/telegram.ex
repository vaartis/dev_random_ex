defmodule DevRandom.Platforms.Telegram.PostAttachment do
  @enforce_keys [:file_id, :type]
  defstruct [:file_id, :type]
end

defimpl DevRandom.Platforms.Attachment, for: DevRandom.Platforms.Telegram.PostAttachment do
  import DevRandom, only: [tg_req: 2]

  def type(data), do: data.type

  defp photo_url(data) do
    %{"ok" => true, "result" => %{"file_path" => file_path}} =
      tg_req("getFile", %{file_id: data.file_id})

    tg_token = Application.get_env(:dev_random_ex, :tg_token)

    "https://api.telegram.org/file/bot#{tg_token}/#{file_path}"
  end

  def phash(data) do
    file_data = HTTPoison.get!(photo_url(data)).body

    case data.type do
      :photo -> {:phash, file_data |> PHash.image_binary_hash!()}
      _ -> {:md5, :crypto.hash(:md5, file_data)}
    end
  end

  def tg_file_string(data), do: {:tg, data.file_id}

  def vk_file_string(data),
    do: DevRandom.Platforms.VK.upload_photo_to_wall(data.type, photo_url(data))
end

defmodule DevRandom.Platforms.Telegram do
  alias DevRandom.Platforms.Post

  @behaviour DevRandom.Platforms.PostSource

  @impl true
  def post() do
    key = :dets.first(BotReceivedImages)

    if key != :"$end_of_table" do
      [{key, post}] = :dets.lookup(BotReceivedImages, key)

      %Post{post | cleanup_data: key}
    else
      nil
    end
  end

  @impl true
  def cleanup(post), do: :dets.delete(BotReceivedImages, post.cleanup_data)
end
