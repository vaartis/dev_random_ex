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
      {DevRandom.RequestTimeAgent, []},
      {DevRandom.Messages, args}
    ]
    Supervisor.start_link(msgs_child, [strategy: :one_for_one, name: DevRandom.UtilsSupervisor])

    {
      :ok,
      Map.merge(
        %{stats: null_stats()}, # Add empty stats
        args
      )
    }
  end

  def handle_cast(:post, state) do
    Process.sleep(1000) # Just in case

    # Check the suggested posts
    {:ok, suggested_posts_query} = vk_req(
      "wall.get",
      %{
        owner_id: -state.group_id,
        filter: "suggests"
      },
    state)

    post_count = suggested_posts_query["count"]

    if post_count > 0 do # There are suggested posts
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
      suggested_post_id = suggested_post["id"] # Select the random post

      # Check if post has attachments and there are images in them
      if Map.has_key?(suggested_post, "attachments") and maybe_use_attachments(suggested_post["attachments"]) do

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

        text = if state[:stats] != null_stats() do
          stats = state[:stats]
          "\nСтатистика предложенного поста:" <>
          (if stats[:skipped_no_atts] > 0, do: "\nПропущено постов без картинок: #{stats[:skipped_no_atts]}", else: "") <>
          (if stats[:skipped_already_used] > 0, do: "\nПропущено уже использованных картинок: #{stats[:skipped_already_used]}", else: "") <>
          ("\nИтого попыток: #{stats[:tries]}")
        else
          ""
        end

        case vk_req(
              "wall.post",
              %{
                owner_id: -state.group_id,
                post_id: suggested_post_id,
                signed: signed,
                message: maybe_anon_text <> text,
                atachments: attachments_text
              },
              state
            ) do
          {:ok, _} -> :ok
          {:error, e} ->
          # 50 posts per day, too much
          if e["error_code"] == 214, do: Logger.error "50 posts per day reached, can't post anything this iteration"
        end

        state = Map.put(state, :stats, null_stats())

        {:noreply, state}
      else
        # Delete the post and restart if there's no attachments or all of them were used recently
        delete_suggested_post(suggested_post_id, state)

        # Increment skip-due-to-no-atts stat
        state = inc_stat(state, :skip_no_atts)

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
        {:error, _}->
          state = inc_stat(state, :skipped_deleted)

          handle_cast(:post, state) # The user's account is probably deleted or something, just restart
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

                image_hash = :crypto.hash(:md5, HTTPoison.get!(random_photo["photo_75"]).body)
                if not image_used_recently?(image_hash) do
                  use_image(image_hash)

                  text = if state[:stats] != null_stats() do
                    stats = state[:stats]
                    "Статистика автоматического поста:" <>
                    (if stats[:skipped_no_saved] > 0, do: "\nПропущено пользователей без сохранённых картинок: #{stats[:skipped_no_saved]}", else: "") <>
                    (if stats[:skipped_closed_saved] > 0, do: "\nПропущено пользователей с закрытым альбомом сохранённых картинок: #{stats[:skipped_closed_saved]}", else: "") <>
                    (if stats[:skipped_already_used] > 0, do: "\nПропущено уже использованных картинок: #{stats[:skipped_already_used]}", else: "") <>
                    (if stats[:skipped_deleted] > 0, do: "\nПропущено удалённых пользователей: #{stats[:skipped_deleted]}", else: "") <>
                    ("\nИтого попыток: #{stats[:tries]}")
                  else
                    ""
                  end

                  case vk_req(
                        "wall.post",
                        %{
                          message: text,
                          owner_id: -state.group_id,
                          attachments: "photo#{random_member}_#{random_photo_id}",
                          signed: 1
                        },
                        state
                      ) do
                    {:ok, _} -> :ok
                    {:error, e} ->
                    # 50 posts per day, too much
                    if e["error_code"] == 214, do: Logger.error "50 posts per day reached, can't post anything this iteration"
                  end

                  state = Map.put(state, :stats, null_stats())

                  {:noreply, state}
                else
                  # Image was used recently
                  state = inc_stat(state, :skipped_already_used)

                  handle_cast(:post, state)
                end
              else
                # The user did not have ant saved images
                state = inc_stat(state, :skipped_no_saved)

                handle_cast(:post, state)
              end
            else
              # The user's "saved images" album is closed
              state = inc_stat(state, :skipped_closed_saved)

              handle_cast(:post, state)
            end
     end
    end
  end

  ## Helpers

  def null_stats, do: %{skipped_no_atts: 0, skipped_no_saved: 0, skipped_closed_saved: 0, skipped_already_used: 0, skipped_deleted: 0, tries: 0}

  @doc """
  Increments a statistic and add a "failed try"
  """
  def inc_stat(state, key) do
    state |>
      Map.put(:stats, Map.update(state[:stats], key, nil, &(&1 + 1))) |> # Increment the stat
      Map.put(:stats, Map.update(state[:stats], :tries, nil, &(&1 + 1))) # Increment tries
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

  @typedoc "A type that VK returns from requests"
  @type vk_result_t :: {:ok, map} | {:error, map | :invalid_method}

  @doc """
  Make a VK request to the `method_name` endpoint with the specified `params`,
  propagating the error (extracting it from the `error` field).

  If VK returns one or unwrapping the returned `response`. If VK returns a 403 page,
  then the error will be reported as `{:error, :invalid_method}`
  """
  @spec vk_req(method_name :: String.t, params :: map, state :: map)
  :: vk_result_t
  def vk_req(method_name, params, state) do

    DevRandom.RequestTimeAgent.before_request()
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
