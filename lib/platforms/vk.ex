defmodule DevRandom.Platforms.VK do
  def random_post_or_posts do
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

      # Check if post has attachments and there are images in them
      if Map.has_key?(suggested_post, "attachments") and
           suggested_post["attachments"]
           |> Enum.filter(fn att -> att["type"] in ["photo", "doc"] end)
           |> Enum.count() > 0 do
        # Return the whole post
        {:suggested, suggested_post}
      else
        # Delete the post and restart if there's no attachments
        delete_suggested_post(suggested_post_id)

        # Select another post
        random_post_or_posts()
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
        {:saved,
         random_from(%{
           method_name: "photos.get",
           all_count: saved_photos_count,
           per_page_count: 1000,
           request_args: %{
             owner_id: random_member,
             album_id: "saved"
           },
           first_page: saved_photos_query["items"]
         })}
      else
        # Try searching for posts again if anything fails
        _ -> random_post_or_posts()
      end
    end
  end

  # Helpers

  @typedoc "A type that VK returns from requests"
  @type vk_result_t :: {:ok, map} | {:error, map | :invalid_method}

  @doc """
  Make a VK request to the `method_name` endpoint with the specified `params`,
  propagating the error (extracting it from the `error` field).

  If VK returns one or unwrapping the returned `response`. If VK returns a 403 page,
  then the error will be reported as `{:error, :invalid_method}`
  """
  @spec vk_req(method_name :: String.t(), params :: map) ::
          vk_result_t
  def vk_req(method_name, params) do
    token = Application.get_env(:dev_random_ex, :token)

    __MODULE__.RequestTimeAgent.before_request()

    query_result =
      HTTPoison.get!(
        "https://api.vk.com/method/#{method_name}",
        [],
        params: Map.merge(params, %{access_token: token, v: "5.73"})
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

  @doc """
  Select a random entity from a paged series of requests.

  `all_count` is how much of entities there are, `per_page_count` is how
  much to fetch per page, `request_args` are additional arguments to `vk_req/3`,
  `method_name` is the method name passed to `vk_req/3`, `first_page` is the page that
  was fetched to retreive the number of images before
  """
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

  @doc """
  Deletes the specified post, returning the request result.
  """
  @spec delete_suggested_post(post_id :: integer) ::
          vk_result_t
  def delete_suggested_post(post_id) do
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
