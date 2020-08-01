defprotocol DevRandom.Platforms.Attachment do
  def type(data)

  def phash(data)

  @doc "A string that contains data to upload the attachment (a URL or a file_id)"
  def tg_file_string(data)

  def vk_file_string(data)
end

defmodule DevRandom.Platforms.Post do
  @enforce_keys [:attachments]
  defstruct [:attachments, :text, :cleanup_data, :source_link]
end

defmodule DevRandom.Platforms.PostSource do
  @callback post() :: DevRandom.Platforms.Post | nil
  @callback cleanup(DevRandom.Platforms.Post) :: :ok | {:error, term}
end
