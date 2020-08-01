defmodule DevRandom.Platforms.OldDanbooru.PostAttachment do
  @enforce_keys [:url, :type, :phash]

  defstruct [:url, :type, :phash]
end

defimpl DevRandom.Platforms.Attachment, for: DevRandom.Platforms.OldDanbooru.PostAttachment do
  def type(data), do: data.type
  def phash(data), do: data.phash
  def tg_file_string(data), do: data.url
  def vk_file_string(data), do: DevRandom.Platforms.VK.upload_photo_to_wall(data.type, data.url)
end

defmodule DevRandom.Platforms.OldDanbooru do
  alias DevRandom.Platforms.Post
  alias DevRandom.Platforms.OldDanbooru.PostAttachment

  def post(base_url) do
    import SweetXml

    random_image =
      ExternalService.call!(
        __MODULE__.Fuse,
        %ExternalService.RetryOptions{
          backoff: {:exponential, 5_000},
          rescue_only: [HTTPoison.Error]
        },
        fn ->
          {total_images, ""} =
            HTTPoison.get!("#{base_url}/index.php?page=dapi&s=post&q=index&limit=1", [],
              timeout: 60_000
            ).body
            |> xpath(~x"//posts/@count"l)
            |> List.first()
            |> to_string
            |> Integer.parse()

          pages = Integer.floor_div(total_images, 100)
          random_page = Enum.random(1..pages)

          HTTPoison.get!(
            "#{base_url}/index.php?page=dapi&s=post&q=index&limit=100&json=1&pid=#{random_page}",
            [],
            timeout: 60_000
          ).body
          |> Poison.decode!()
          |> Enum.random()
        end
      )

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

    {:ok, phash} = HTTPoison.get!(url).body |> PHash.image_binary_hash()

    %Post{
      attachments: [
        %PostAttachment{
          type: type,
          url: url,
          phash: phash
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
