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

  @spec init(args :: map) :: {atom, map}
  def init(%{token: token, group_id: group_id} = args) when token != nil and group_id != nil do
    msgs_child = [
      {DevRandom.Platforms.VK.RequestTimeAgent, []},
      {DevRandom.Messages, []}
    ]

    Supervisor.start_link(msgs_child, strategy: :one_for_one, name: DevRandom.UtilsSupervisor)

    {
      :ok,
      args
    }
  end

  def handle_cast(:post, state) do
    tg_group_id = Application.get_env(:dev_random_ex, :tg_group_id)

    sources = [
      DevRandom.Platforms.Telegram,
      DevRandom.Platforms.VK
    ]

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
                {"sendAnimation", :animation, Attachment.tg_file_string(att)}

              # Image
              :photo ->
                {"sendPhoto", :photo, Attachment.tg_file_string(att)}

              # Other
              :other ->
                {"sendDocument", :document, Attachment.tg_file_string(att)}
            end
          end
        )

      case tfed_attachments do
        [{endpointName, parameterName, url}] ->
          # Send the request to the selected endpoint with a parmeter
          # named parameterName, as all these endpoints have different
          # parameter names
          tg_req(endpointName, %{
            :chat_id => tg_group_id,
            parameterName => url,
            :caption => post.text,
            :parse_mode => "Markdown"
          })

        atts ->
          text_msg_id =
            if post.text do
              %{"ok" => true, "result" => %{"message_id" => text_msg_id}} =
                tg_req("sendMessage", %{
                  chat_id: tg_group_id,
                  text: post.text,
                  parse_mode: "Markdown"
                })

              text_msg_id
            end

          Enum.each(
            atts,
            fn {endpointName, parameterName, url} ->
              tg_req(endpointName, %{
                :chat_id => tg_group_id,
                parameterName => url,
                :reply_to_message_id => text_msg_id
              })
            end
          )
      end
    end

    source.cleanup(post)

    {:noreply, state}
  end

  def tg_req(method_name, params) do
    tg_token = Application.get_env(:dev_random_ex, :tg_token)

    query_result =
      HTTPoison.post!(
        "https://api.telegram.org/bot#{tg_token}/#{method_name}",
        Jason.encode!(params),
        [{"content-type", "application/json"}],
        recv_timeout: :infinity
      )

    Poison.decode!(query_result.body)
  end

  def maybe_use_attachments(attachments) do
    attachment_hashes =
      attachments
      |> Enum.map(fn a -> Attachment.md5(a) end)

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
      [{^image_hash, %{last_used: date, next_use_allowed_in: next_use_allowed_in}}] =
        lookup_result

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
      {^image_hash, %{next_use_allowed_in: next_use_allowed_in}} = List.first(lookup_result)

      # Make the next allowed use time twice as long
      :dets.insert(
        RecentImages,
        {image_hash, %{last_used: Timex.today(), next_use_allowed_in: next_use_allowed_in * 2}}
      )
    end
  end
end
