defmodule DevRandom.Platforms.VK.PostAttachment do
  @enforce_keys [:url, :type, :vk_string]
  @doc """
  - `url` is the URL of the attachment
  - `type` is the type of the attachment (:photo, :animation, :other)
  - `hashing_url` is the URL to download from when hashing for deduplication
  """
  defstruct [:url, :type, :hashing_url, :vk_string, :suggested_post_id]
end

defimpl DevRandom.Platforms.Attachment, for: DevRandom.Platforms.VK.PostAttachment do
  def type(data), do: data.type

  def phash(data) do
    {
      :phash,
      # Apparently VK responds with a redirect sometimes
      HTTPoison.get!(data.hashing_url, [], timeout: 60_000, follow_redirect: true).body
      |> PHash.image_binary_hash!()
    }
  end

  def tg_file_string(data), do: {:url, data.url}

  def vk_file_string(data), do: data.vk_string
end

defmodule DevRandom.Platforms.VK do
  alias DevRandom.Platforms.Post

  alias DevRandom.Platforms.VK.PostAttachment

  @behaviour DevRandom.Platforms.PostSource

  @impl true
  def cleanup(_data), do: nil

  @impl true
  def post(tries \\ 0) do
    group_id = Application.get_env(:dev_random_ex, :group_id)

    # There are suggested posts
    {:ok, members_query} =
      vk_req(
        "groups.getMembers",
        %{group_id: group_id}
      )

    members_count = members_query["count"]

    random_member =
      random_from(%{
        method_name: "groups.getMembers",
        all_count: members_count,
        per_page_count: 1000,
        request_args: %{
          group_id: group_id
        },
        first_page: members_query["items"]
      })

    # Get the user's albums first
    with {:ok, %{"items" => albums}} <-
           vk_req("photos.getAlbums", %{owner_id: random_member, need_system: 1}),
         # There's a saved pictures album
         true <- Enum.any?(albums, &(&1["id"] == -15)),
         # Get the album info
         {:ok, saved_photos_query} <-
           vk_req(
             "photos.get",
             %{
               owner_id: random_member,
               album_id: "saved"
             }
           ),
         # Get the amount of saved photos
         saved_photos_count <- saved_photos_query["count"],
         # There are any photos in there
         true <- saved_photos_count > 0 do
      random_saved =
        random_from(%{
          method_name: "photos.get",
          all_count: saved_photos_count,
          per_page_count: 1000,
          request_args: %{
            owner_id: random_member,
            album_id: "saved"
          },
          first_page: saved_photos_query["items"]
        })

      smallest = List.first(random_saved["sizes"])["url"]
      biggest = List.last(random_saved["sizes"])["url"]

      %Post{
        attachments: [
          %PostAttachment{
            type: :photo,
            url: biggest,
            hashing_url: smallest,
            vk_string: "photo#{random_saved["owner_id"]}_#{random_saved["id"]}"
          }
        ],
        source_link: "https://vk.com/photo#{random_saved["owner_id"]}_#{random_saved["id"]}"
      }
    else
      _ ->
        # Try searching for posts again if anything fails, and just exit if try limit is exhausted
        if tries < Application.get_env(:dev_random_ex, :vk_max_search_tries) do
          post(tries + 1)
        end
    end
  end

  # Helpers

  @typedoc "A type that VK returns from requests"
  @type vk_result_t :: {:ok, map} | {:error, map | :invalid_method}

  # Make a VK request to the `method_name` endpoint with the specified `params`,
  # propagating the error (extracting it from the `error` field).
  #
  # If VK returns one or unwrapping the returned `response`. If VK returns a 403 page,
  # then the error will be reported as `{:error, :invalid_method}`
  @spec vk_req(method_name :: String.t(), params :: map) ::
          vk_result_t
  def vk_req(method_name, params \\ %{}) do
    token = Application.get_env(:dev_random_ex, :token)

    query_result =
      ExternalService.call!(
        __MODULE__.Fuse,
        %ExternalService.RetryOptions{
          backoff: {:exponential, 5_000},
          rescue_only: [HTTPoison.Error]
        },
        fn ->
          HTTPoison.get!(
            "https://api.vk.com/method/#{method_name}",
            [],
            params: Map.merge(%{access_token: token, v: "5.122"}, params),
            timeout: 60_000
          )
        end
      )

    if query_result.status_code == 403 do
      # VK doesnt actually return an error on invalid method, although it should,
      # so we'll do it ourselves
      {:error, :invalid_method}
    else
      result = Poison.decode!(query_result.body)

      # Propagate the error if there is one
      if Map.has_key?(result, "error") do
        {:error, result["error"]}
      else
        {:ok, result["response"]}
      end
    end
  end

  #
  # Select a random entity from a paged series of requests.
  #
  # `all_count` is how much of entities there are, `per_page_count` is how
  # much to fetch per page, `request_args` are additional arguments to `vk_req/3`,
  # `method_name` is the method name passed to `vk_req/3`, `first_page` is the page that
  # was fetched to retreive the number of images before
  #
  @spec random_from(
          params :: %{
            method_name: String.t(),
            all_count: integer,
            per_page_count: integer,
            request_args: map,
            first_page: [...]
          }
        ) :: term
  def random_from(%{
        method_name: method_name,
        all_count: all_count,
        per_page_count: per_page_count,
        request_args: request_args,
        first_page: first_page
      }) do
    Enum.random(
      if all_count > per_page_count do
        total_pages = div(all_count, per_page_count)

        get_page = fn page ->
          {:ok, current_page} =
            vk_req(
              method_name,
              Map.merge(%{count: per_page_count, offset: page * per_page_count}, request_args)
            )

          current_page["items"]
        end

        # Use the first 100 entities as the beginning, then collect other pages begging from
        # the second one (there must me at least two pages if there's more then `per_page_count` entities)
        first_page ++ Enum.flat_map(2..total_pages, &get_page.(&1))
      else
        # Just return what we already had
        first_page
      end
    )
  end

  def upload_photo_to_wall(type, url) do
    data =
      (
        downloaded = HTTPoison.get!(url).body

        case type do
          :photo ->
            downloaded

          :animation ->
            import FFmpex
            use FFmpex.Options

            filename = Path.basename(url)
            extname = Path.extname(filename)

            if extname == ".gif" do
              downloaded
            else
              Temp.track!()
              path = Temp.open!([suffix: filename], &IO.binwrite(&1, downloaded))

              gif_path = String.replace_suffix(path, extname, ".gif")

              palette_path = Temp.path!(suffix: ".png")

              :ok =
                FFmpex.new_command()
                |> add_input_file(path)
                |> add_output_file(palette_path)
                |> add_file_option(option_filter("palettegen"))
                |> execute()

              :ok =
                FFmpex.new_command()
                |> add_input_file(path)
                |> add_input_file(palette_path)
                |> add_output_file(gif_path)
                |> add_global_option(option_filter_complex("paletteuse"))
                |> execute()

              result = File.read!(gif_path)

              Temp.cleanup()

              result
            end
        end
      )

    group_id = Application.get_env(:dev_random_ex, :group_id)

    {method, field, params} =
      case type do
        :photo -> {"photos.getWallUploadServer", "photo", %{group_id: group_id}}
        _ -> {"docs.getUploadServer", "file", %{}}
      end

    {:ok, %{"upload_url" => upload_url}} = vk_req(method, params)

    filename =
      cond do
        # If there's no extension, assume it's jpg since it probably comes from telegram
        type == :photo and Path.extname(url) == "" -> Path.basename(url) <> ".jpg"
        true -> Path.basename(url)
      end

    upload_result =
      HTTPoison.post!(
        upload_url,
        {:multipart,
         [{field, data, {"form-data", [{"name", field}, {"filename", filename}]}, []}]}
      ).body
      |> Poison.decode!()

    case type do
      :photo ->
        %{"server" => server, "photo" => photo, "hash" => hash} = upload_result

        {:ok, [saved_photo]} =
          vk_req(
            "photos.saveWallPhoto",
            %{server: server, photo: photo, hash: hash, group_id: group_id}
          )

        "photo#{saved_photo["owner_id"]}_#{saved_photo["id"]}"

      _ ->
        %{"file" => file} = upload_result

        {:ok, %{"doc" => %{"owner_id" => owner_id, "id" => id}}} =
          vk_req(
            "docs.save",
            %{file: file}
          )

        "doc#{owner_id}_#{id}"
    end
  end

  @anon_regex ~r/^(anon)|(анон)/i
  def make_vk_post(post) do
    group_id = Application.get_env(:dev_random_ex, :group_id)

    text = if post.text, do: post.text, else: ""

    is_anon = Regex.match?(@anon_regex, text)
    text = Regex.replace(@anon_regex, text, "")

    case Enum.at(post.attachments, 0) do
      %PostAttachment{suggested_post_id: post_id} when post_id != nil ->
        vk_req(
          "wall.post",
          %{
            owner_id: -group_id,
            post_id: post_id,
            message: text,
            signed: if(is_anon, do: 0, else: 1),
            copyright: post.source_link,
            attachments:
              post.attachments
              |> Enum.map(&DevRandom.Platforms.Attachment.vk_file_string/1)
              |> Enum.join(",")
          }
        )

      _ ->
        vk_attachment_strings =
          Enum.map(post.attachments, &DevRandom.Platforms.Attachment.vk_file_string/1)

        vk_req(
          "wall.post",
          %{
            owner_id: -group_id,
            message: text,
            signed: 0,
            attachments: Enum.join(vk_attachment_strings, ","),
            copyright:
              case post.source_link do
                {:telegram, _, _} -> nil
                link -> link
              end
          }
        )
    end
  end
end

defmodule DevRandom.Platforms.VK.Suggested do
  require Logger

  alias DevRandom.Platforms.Post
  alias DevRandom.Platforms.VK.PostAttachment

  @behaviour DevRandom.Platforms.PostSource

  import DevRandom.Platforms.VK, only: [vk_req: 2, random_from: 1]

  @impl true
  def cleanup(_data), do: nil

  @impl true
  def post do
    group_id = Application.get_env(:dev_random_ex, :group_id)

    can_post =
      (
        {:ok, %{"items" => posts}} =
          DevRandom.Platforms.VK.vk_req("wall.get", %{owner_id: -112_376_753, count: 50})

        today = Timex.today()

        times =
          Enum.map(posts, &Timex.from_unix(&1["date"]))
          |> Enum.map(&DateTime.to_date/1)
          |> Enum.filter(fn date -> date == today end)

        # If there are less than 50 posts today, new can be made
        Enum.count(times) < 50
      )

    if can_post do
      # Check the suggested posts
      {:ok, suggested_posts_query} =
        vk_req(
          "wall.get",
          %{
            owner_id: -group_id,
            filter: "suggests"
          }
        )

      post_count = suggested_posts_query["count"]

      # There are suggested posts
      if post_count > 0 do
        suggested_post =
          random_from(%{
            method_name: "wall.get",
            all_count: post_count,
            per_page_count: 100,
            request_args: %{
              owner_id: -group_id,
              filter: "suggests"
            },
            first_page: suggested_posts_query["items"]
          })

        # Select the random post
        suggested_post_id = suggested_post["id"]

        with true <- Map.has_key?(suggested_post, "attachments"),
             # Filter the attachments
             filtered_atts <-
               suggested_post["attachments"]
               |> Enum.filter(fn att -> att["type"] in ["photo", "doc"] end)
               # Discard everything except gifs and pictures
               |> Enum.filter(fn att -> att["photo"] || att["doc"]["type"] in [3, 4] end),
             # Any attachments left?
             true <- Enum.count(filtered_atts) > 0 do
          attachments =
            Enum.map(
              filtered_atts,
              fn
                %{"photo" => photo, "type" => "photo"} ->
                  smallest = List.first(photo["sizes"])["url"]
                  biggest = List.last(photo["sizes"])["url"]

                  %PostAttachment{
                    type: :photo,
                    # URL for the image
                    url: biggest,
                    # URL for the smallest image to hash it
                    hashing_url: smallest,
                    # VK name for the photo
                    vk_string: "photo#{photo["owner_id"]}_#{photo["id"]}",
                    suggested_post_id: suggested_post_id
                  }

                %{
                  "doc" => %{
                    "type" => doc_type,
                    "url" => doc_url,
                    "owner_id" => owner_id,
                    "id" => id
                  },
                  "type" => "doc"
                } ->
                  type =
                    case doc_type do
                      # GIF
                      3 ->
                        :animation

                      # Image
                      4 ->
                        :photo
                    end

                  %PostAttachment{
                    type: type,
                    url: doc_url,
                    hashing_url: doc_url,
                    vk_string: "doc#{owner_id}_#{id}",
                    # Just store it in attachments since posts are uniform
                    suggested_post_id: suggested_post_id
                  }
              end
            )

          %Post{
            attachments: attachments,
            text: if(suggested_post["text"] != "", do: suggested_post["text"], else: nil),
            source_link: suggested_post["copyright"]["link"]
          }
        else
          _ ->
            # Delete the post
            delete_suggested_post(suggested_post_id)

            # Select another post
            post()
        end
      end
    else
      Logger.info(
        "Can't post to VK wall, probably reached post limit. Will not try using suggested posts."
      )

      nil
    end
  end

  # Deletes the specified post, returning the request result.
  defp delete_suggested_post(post_id) do
    group_id = Application.get_env(:dev_random_ex, :group_id)

    vk_req(
      "wall.delete",
      %{
        owner_id: -group_id,
        post_id: post_id
      }
    )
  end
end
