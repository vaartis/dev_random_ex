defmodule DevRandom do
  use GenServer

  @typedoc "A type that VK returns from requests"
  @type vk_result_t :: {:ok, map} | {:error, map | :invalid_method}

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  ## Callbacks

  @spec init(args :: map) :: {atom, map}
  def init(%{token: token, group_id: group_id} = args) when token != nil and group_id != nil do
    vk_req("users.report", %{user_ids: -1}, args)
    {:ok, args}
  end

  def handle_cast(:post, state) do
    {:ok, suggested_posts_query} = vk_req(
      "wall.get",
      %{
        owner_id: -state.group_id,
        filter: "suggests"
      },
    state)

    post_count = suggested_posts_query["count"]

    if post_count > 0 do
      suggested_post = random_from(
        %{
          method_name: "wall.get",
          all_count: post_count,
          per_page_count: 100,
          request_args: %{
            owner_id: -state.group_id,
            filter: "suggests"
          },
          first_page: suggested_posts_query["items"]
        },
        state
      )
      suggested_post_id = suggested_post["id"]

      # Check if post has attachments and there are images in them
      if Map.has_key?(suggested_post, "attachments")
      and Enum.any?(
        suggested_post["attachments"],
        &(&1["type"] in ["photo", "doc"])
      ) do

        signed = (if String.contains?(String.downcase(suggested_post["text"]), "анон"), do: 0, else: 1)
        maybe_anon_text = Regex.replace(~r/анон/iu, suggested_post["text"], "", [global: false])
        attachments_text = Enum.map_join(
          suggested_post["attachments"],
          ",",
          fn attachment ->
            type = attachment["type"]
            info = attachment[type]
            "#{type}#{info["owner_id"]}_#{info["id"]}"
          end
        )

        {:ok, _} = vk_req(
          "wall.post",
          %{
            owner_id: -state.group_id,
            post_id: suggested_post_id,
            signed: signed,
            message: maybe_anon_text,
            atachments: attachments_text
          },
          state
        )
      else
        # Delete the post and restart if there's no attachments
        delete_suggested_post(suggested_post_id, state)
        handle_cast(:post, state)
      end
    else
      {:ok, members_query} = vk_req(
        "groups.getMembers",
        %{group_id: state.group_id},
        state
      )

      members_count = members_query["count"]

      random_member = random_from(
        %{
          method_name: "groups.getMembers",
          all_count: members_count,
          per_page_count: 1000,
          request_args: %{
            group_id: state.group_id
          },
          first_page: members_query["items"]
        },
        state
      )

      maybe_album_query = vk_req("photos.getAlbums", %{owner_id: random_member, need_system: 1}, state)
      case maybe_album_query do
        {:error, _}-> handle_cast(:post, state)
        {:ok, album_query} ->
            albums = album_query["items"]

            # There are saved photos
            if Enum.any?(albums, &(&1["id"] == -15)) do
              {:ok, saved_photos_query} = vk_req(
                "photos.get",
                %{
                  owner_id: random_member,
                  album_id: "saved"
                },
                state
              )

              saved_photos_count = saved_photos_query["count"]

              if saved_photos_count > 0 do
                random_photo = random_from(
                  %{
                    method_name: "photos.get",
                    all_count: saved_photos_count,
                    per_page_count: 1000,
                    request_args: %{
                      owner_id: random_member,
                      album_id: "saved"
                    },
                    first_page: saved_photos_query["items"]
                  },
                  state
                )
                random_photo_id = random_photo["id"]

                {:ok, _} = vk_req(
                  "wall.post",
                  %{
                    owner_id: -state.group_id,
                    attachments: "photo#{random_member}_#{random_photo_id}",
                    signed: 1
                  },
                  state
                )
              else
                handle_cast(:post, state)
              end
            else
              handle_cast(:post, state)
            end
     end
    end

    {:noreply, state}
  end

  def handle_cast(:messages, state) do
    require IEx

    {:ok, dialogs} = vk_req("messages.getDialogs", %{unread: 1}, state)

    Enum.each(dialogs["items"], fn dialog ->
      message = dialog["message"]

      if (not Map.has_key?(message, "chat_id")) and Map.has_key?(message, "body") do
        sender_id = message["user_id"]

        if Regex.match?(~r/предложк/iu, message["body"]) do
          {:ok, sugg_posts} = vk_req(
            "wall.get",
            %{
              owner_id: -state.group_id,
              filter: "suggests"
            },
            state
          )

          case vk_req("messages.send", %{user_id: sender_id, message: sugg_posts["count"]}, state) do
            {:error, %{"error_code" => 7}} ->
              # Account is probably deleted or messages are blocked
              {:ok, 1} = vk_req(
              "messages.markAsRead",
              %{peer_id: sender_id, start_message_id: message["id"]},
              state)
            {:ok, _} -> nil # All good
          end
        end
      end
    end)

    {:noreply, state}
  end

  ## Helpers

  @doc """
  Select a random entity from a paged series of requests.

  `all_count` is how much of entities there are, `per_page_count` is how
  much to fetch per page, `request_args` are additional arguments to `vk_req/3`,
  `method_name` is the method name passed to `vk_req/3`, `first_page` is the page that
  was fetched to retreive the number of images before
  """
  @spec random_from(
    params :: %{
      method_name: String.t,
      all_count: integer,
      per_page_count: integer,
      request_args: map,
      first_page: [...]
    },
    state :: map) :: term
  def random_from(
    %{
      method_name: method_name,
      all_count: all_count,
      per_page_count: per_page_count,
      request_args: request_args,
      first_page: first_page
    },
    state
  ) do
    Enum.random(if all_count > per_page_count do
      total_pages = div(all_count, per_page_count)

      get_page = fn page ->
        {:ok, current_page} = vk_req(
        method_name,
        Map.merge(%{count: per_page_count, offset: page * per_page_count}, request_args),
        state)

        current_page["items"]
      end


      # Use the first 100 entities as the beginning, then collect other pages begging from
      # the second one (there must me at least two pages if there's more then `per_page_count` entities)
      first_page ++ Enum.flat_map(2..total_pages, &get_page.(&1))
    else
      # Just return what we already had
      first_page
    end)
  end

  @doc """
  Deletes the specified post, returning the request result.
  """
  @spec delete_suggested_post(post_id :: integer, state :: map)
  :: vk_result_t
  def delete_suggested_post(post_id, state) do
    vk_req(
      "wall.delete",
      %{
        owner_id: -state.group_id,
        post_id: post_id
      },
      state
    )
  end

  @doc """
  Make a VK request to the `method_name` endpoint with the specified `params`,
  propagating the error (extracting it from the `error` field).

  If VK returns one or unwrapping the returned `response`. If VK returns a 403 page,
  then the error will be reported as `{:error, :invalid_method}`
  """
  @spec vk_req(method_name :: String.t, params :: map, state :: map)
  :: vk_result_t
  def vk_req(method_name, params, state) do
    query_result = HTTPoison.get!(
      "https://api.vk.com/method/#{method_name}",
      [],
      [
        params: Map.merge(params, %{access_token: state.token, v: "5.73"})
      ])

    if query_result.status_code == 403 do
      # VK doesnt actually return an error on invalid method, although it should,
      # so we'll do it ourselves
      {:error, :invalid_method}
    else
      result = Poison.decode! query_result.body

      # Propagate the error if there is one
      if Map.has_key?(result, "error") do
        {:error, result["error"]}
      else
        {:ok, result["response"]}
      end
    end
  end
end
