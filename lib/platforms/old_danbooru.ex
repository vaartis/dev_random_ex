defmodule DevRandom.Platforms.OldDanbooru.PostAttachment do
  @enforce_keys [:url, :type]

  defstruct [:url, :type, :md5]
end

defimpl DevRandom.Platforms.Attachment, for: DevRandom.Platforms.OldDanbooru.PostAttachment do
  def type(data), do: data.type
  def md5(data), do: data.md5
  def tg_file_string(data), do: data.url
  def vk_file_string(data), do: DevRandom.Platforms.VK.upload_photo_to_wall(data.type, data.url)
end

defmodule DevRandom.Platforms.OldDanbooru do
  alias DevRandom.Platforms.Post
  alias DevRandom.Platforms.OldDanbooru.PostAttachment

  def post(base_url) do
    import SweetXml

    {total_images, ""} =
      HTTPoison.get!("#{base_url}/index.php?page=dapi&s=post&q=index&limit=1", [], timeout: 60_000).body
      |> xpath(~x"//posts/@count"l)
      |> List.first()
      |> to_string
      |> Integer.parse()

    pages = Integer.floor_div(total_images, 100)
    random_page = Enum.random(1..pages)

    random_image =
      HTTPoison.get!(
        "#{base_url}/index.php?page=dapi&s=post&q=index&limit=100&json=1&pid=#{random_page}",
        [],
        timeout: 60_000
      ).body
      |> Poison.decode!()
      |> Enum.random()

    type =
      cond do
        String.ends_with?(random_image["image"], ".gif") ->
          :animation

        String.ends_with?(random_image["image"], [".png", ".jpg", ".jpeg"]) ->
          :photo

        true ->
          :other
      end

    url = "#{base_url}/images/#{random_image["directory"]}/#{random_image["image"]}"

    %Post{
      attachments: [
        %PostAttachment{
          type: type,
          url: url,
          md5: random_image["hash"] |> String.upcase()
        }
      ],
      source_link: "#{base_url}/index.php?page=post&s=view&id=#{random_image["id"]}"
    }
  end
end

defmodule DevRandom.Platforms.OldDanbooru.Safebooru do
  alias DevRandom.Platforms.OldDanbooru

  @behaviour DevRandom.Platforms.PostSource

  @base_url "https://safebooru.org"

  @impl true
  def post, do: OldDanbooru.post(@base_url)

  @impl true
  def cleanup(_data), do: :ok
end
