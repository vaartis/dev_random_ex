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
    {:ok, hash} =
      HTTPoison.get!(data.hashing_url, [], timeout: 60_000).body |> PHash.image_binary_hash()

    hash
  end

  def tg_file_string(data), do: data.url

  def vk_file_string(data), do: data.vk_string
end

defmodule DevRandom.Platforms.VK do
  alias DevRandom.Platforms.Post

  alias DevRandom.Platforms.VK.PostAttachment

  @behaviour DevRandom.Platforms.PostSource

  @impl true
  def cleanup(post) do
    if post.cleanup_data && !Enum.at(post.attachments, 0).suggested_post_id,
      do: delete_suggested_post(post.cleanup_data)
  end

  @impl true
  def post do
    # Just in case
    Process.sleep(1000)

    group_id = Application.get_env(:dev_random_ex, :group_id)

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
             |> Enum.filter(fn att -> att["doc"]["type"] in [3, 4] end),
           # Any attachments left?
           true <- Enum.count(filtered_atts) > 0 do
        attachments =
          Enum.map(
            filtered_atts,
            fn
              %{"photo" => photo, "type" => "photo"} ->
                biggest =
                  Enum.find_value(
                    [
                      "photo_2560",
                      "photo_1280",
                      "photo_807",
                      "photo_604",
                      "photo_130",
                      "photo_75"
                    ],
                    fn size -> photo[size] end
                  )

                %PostAttachment{
                  type: :photo,
                  # URL for the image
                  url: biggest,
                  # URL for the smallest image to hash it
                  hashing_url: photo["photo_75"],
                  # VK name for the photo
                  vk_string: "photo#{photo["owner_id"]}_#{photo["id"]}"
                }

              %{"doc" => doc, "type" => "doc"} ->
                type =
                  case doc["type"] do
                    # GIF
                    3 ->
                      :animation

                    # Image
                    4 ->
                      :photo
                  end

                %PostAttachment{
                  type: type,
                  url: doc["url"],
                  hashing_url: doc["url"],
                  vk_string: "doc#{doc["owner_id"]}_#{doc["id"]}",
                  # Just store it in attachments since posts are uniform
                  suggested_post_id: suggested_post_id
                }
            end
          )

        %Post{
          attachments: attachments,
          cleanup_data: suggested_post_id,
          text: if(suggested_post["text"] != "", do: suggested_post["text"], else: nil)
        }
      else
        _ ->
          # Delete the post
          delete_suggested_post(suggested_post_id)

          # Select another post
          post()
      end
    else
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

        biggest =
          Enum.find_value(
            ["photo_2560", "photo_1280", "photo_807", "photo_604", "photo_130", "photo_75"],
            fn size -> random_saved[size] end
          )

        %Post{
          attachments: [
            %PostAttachment{
              type: :photo,
              url: biggest,
              hashing_url: random_saved["photo_75"],
              vk_string: "photo#{random_saved["owner_id"]}_#{random_saved["id"]}"
            }
          ],
          source_link: "https://vk.com/photo#{random_saved["owner_id"]}_#{random_saved["id"]}"
        }
      else
        # Try searching for posts again if anything fails
        _ -> post()
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
  defp vk_req(method_name, params) do
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
            params: Map.merge(params, %{access_token: token, v: "5.73"}),
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
  defp random_from(%{
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

  # Deletes the specified post, returning the request result.
  @spec delete_suggested_post(post_id :: integer) ::
          vk_result_t
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

  def upload_photo_to_wall(type, url) do
    data = HTTPoison.get!(url).body

    group_id = Application.get_env(:dev_random_ex, :group_id)

    {method, field} =
      case type do
        :photo -> {"photos.getWallUploadServer", "photo"}
        _ -> {"docs.getWallUploadServer", "file"}
      end

    {:ok, %{"upload_url" => upload_url}} =
      vk_req(
        method,
        %{group_id: group_id}
      )

    filename = Path.basename(url)

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

        {:ok, [saved_doc]} =
          vk_req(
            "docs.save",
            %{file: file}
          )

        "doc#{saved_doc["owner_id"]}_#{saved_doc["id"]}"
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
            signed: if(is_anon, do: 0, else: 1)
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
