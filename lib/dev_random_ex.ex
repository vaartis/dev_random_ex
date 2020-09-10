defmodule DevRandom do
  require Logger

  use GenServer

  alias DevRandom.Platforms.Attachment

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def post() do
    GenServer.cast(__MODULE__, :post)
  end

  ## Callbacks

  @impl true
  @spec init(args :: map) :: {atom, map}
  def init(%{token: token, group_id: group_id} = args) when token != nil and group_id != nil do
    msgs_child = [
      {DevRandom.Messages, []}
    ]

    DevRandom.Platforms.VK.Fuse.start()
    DevRandom.Platforms.OldDanbooru.Fuse.start()

    Supervisor.start_link(msgs_child, strategy: :one_for_one, name: DevRandom.UtilsSupervisor)

    {
      :ok,
      args
    }
  end

  @impl true
  def handle_cast(:post, state) do
    tg_group_id = Application.get_env(:dev_random_ex, :tg_group_id)

    :random.seed(:os.timestamp())
    # Post from telegram if there's any, and shuffle other possible sources
    sources =
      [
        DevRandom.Platforms.VK.Suggested,
        DevRandom.Platforms.Telegram
      ] ++
        Enum.shuffle([
          DevRandom.Platforms.VK,
          DevRandom.Platforms.OldDanbooru.Safebooru
        ])

    {post, source} =
      Enum.find_value(sources, fn src ->
        post = src.post()
        if post, do: {post, src}
      end)

    if maybe_use_attachments(post.attachments) do
      # transform attachments into a more universal format to
      # send them later
      tfed_attachments =
        Enum.map(
          post.attachments,
          fn att ->
            case att.type do
              # GIF
              :animation ->
                {"sendAnimation", "animation", Attachment.tg_file_string(att)}

              # Image
              :photo ->
                {"sendPhoto", "photo", Attachment.tg_file_string(att)}

              # Other
              :other ->
                {"sendDocument", "document", Attachment.tg_file_string(att)}
            end
          end
        )

      anon_regex = ~r/^(anon)|(анон)/i
      is_anon = Regex.match?(anon_regex, post.text || "")

      source_text =
        case post.source_link do
          {:telegram, fname, user_id} when not is_anon ->
            "from [#{fname}](tg://user?id=#{user_id})\n"

          {:telegram, _, _} when is_anon ->
            ""

          nil ->
            ""

          link ->
            "[Source](#{link})"
        end

      post_text =
        if post.text do
          Regex.replace(anon_regex, post.text, "")
        else
          ""
        end

      text = "#{post_text}\n\n#{source_text}"

      case tfed_attachments do
        [{endpointName, parameterName, url}] ->
          downloaded = HTTPoison.get!(url).body

          # Send the request to the selected endpoint with a parmeter
          # named parameterName, as all these endpoints have different
          # parameter names
          %{"ok" => true} =
            tg_req(
              endpointName,
              [
                {"chat_id", tg_group_id},
                {"caption", text},
                {"parse_mode", "Markdown"},
                {parameterName, downloaded,
                 {"form-data", [{"name", parameterName}, {"filename", Path.basename(url)}]}, []}
              ],
              multipart: true
            )

        atts ->
          text_msg_id =
            (
              %{"ok" => true, "result" => %{"message_id" => text_msg_id}} =
                tg_req("sendMessage", %{
                  chat_id: tg_group_id,
                  text: text,
                  parse_mode: "Markdown"
                })

              text_msg_id
            )

          Enum.each(
            atts,
            fn {endpointName, parameterName, url} ->
              downloaded = HTTPoison.get!(url).body

              %{"ok" => true} =
                tg_req(
                  endpointName,
                  [
                    {"chat_id", tg_group_id},
                    {"reply_to_message_id", text_msg_id},
                    {parameterName, downloaded,
                     {"form-data", [{"name", parameterName}, {"filename", Path.basename(url)}]},
                     []}
                  ],
                  multipart: true
                )
            end
          )
      end
    end

    case DevRandom.Platforms.VK.make_vk_post(post) do
      {:ok, _} ->
        nil

      # VK error for "too many posts per day"
      {:error, %{"error_code" => 214}} ->
        Logger.info("VK post limit reached, will not post there.")
    end

    source.cleanup(post)

    {:noreply, state}
  end

  def tg_req(method_name, params, opts \\ []) do
    tg_token = Application.get_env(:dev_random_ex, :tg_token)

    query_result =
      if opts[:multipart] do
        HTTPoison.post!(
          "https://api.telegram.org/bot#{tg_token}/#{method_name}",
          {:multipart, params},
          recv_timeout: :infinity
        )
      else
        HTTPoison.post!(
          "https://api.telegram.org/bot#{tg_token}/#{method_name}",
          Jason.encode!(params),
          [{"content-type", "application/json"}],
          recv_timeout: :infinity
        )
      end

    Poison.decode!(query_result.body)
  end

  def maybe_use_attachments(attachments) do
    attachment_hashes =
      attachments
      |> Enum.map(fn a -> Attachment.phash(a) end)

    if Enum.all?(attachment_hashes, &image_used_recently?/1) do
      false
    else
      Enum.each(attachment_hashes, &use_image/1)

      true
    end
  end

  def image_recent_lookup(image_hash) do
    exact_match = :dets.lookup(RecentImages, image_hash)

    if Enum.empty?(exact_match) and match?({:phash, _}, image_hash) do
      :dets.traverse(
        RecentImages,
        fn {hash, _} = value ->
          with {:phash, hash} <- hash,
               {:phash, image_hash} <- image_hash,
               true <- PHash.image_hash_distance(hash, image_hash) < 5 do
            [value]
          else
            _ -> :continue
          end
        end
      )
    else
      exact_match
    end
  end

  @doc """
  Checks if the image was used recently
  """
  def image_used_recently?(image_hash) do
    use Timex

    lookup_result = image_recent_lookup(image_hash)

    if Enum.empty?(lookup_result) do
      # The image was not used
      false
    else
      [{_, %{last_used: date, next_use_allowed_in: next_use_allowed_in}}] = lookup_result

      # Image was posted withing the next allowed use interval
      Timex.today() in Timex.Interval.new(from: date, until: [days: next_use_allowed_in])
    end
  end

  @doc """
  Mark image as used in DETS.
  """
  def use_image(image_hash) do
    lookup_result = :dets.lookup(RecentImages, image_hash)

    if Enum.empty?(lookup_result) do
      # Let it be two weeks for starters
      :dets.insert(
        RecentImages,
        {image_hash, %{last_used: Timex.today(), next_use_allowed_in: 14}}
      )
    else
      # Get the last use
      {_, %{next_use_allowed_in: next_use_allowed_in}} = List.first(lookup_result)

      # Make the next allowed use time twice as long
      :dets.insert(
        RecentImages,
        {image_hash, %{last_used: Timex.today(), next_use_allowed_in: next_use_allowed_in * 2}}
      )
    end
  end

  @impl true
  def terminate(reason, _) when reason not in [:normal, :shutdown] do
    env = Application.get_env(:dev_random_ex, DevRandom.Mailer)

    if env[:enabled] do
      import Swoosh.Email

      body = """
      Error:
      #{inspect(reason, pretty: true)}
      """

      new()
      |> to(env[:to])
      |> from("DevRandomEx")
      |> subject("Error in dev_random_ex")
      |> text_body(body)
      |> DevRandom.Mailer.deliver!()
    end
  end
end
