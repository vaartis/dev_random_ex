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
    full_url = photo_url(data)

    {:ok, hash} = HTTPoison.get!(full_url).body |> PHash.image_binary_hash()

    hash
  end

  def tg_file_string(data), do: data.file_id

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
