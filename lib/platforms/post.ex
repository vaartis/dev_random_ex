defmodule DevRandom.Platforms.PostAttachment do
  @enforce_keys [:url, :type]
  defstruct [:url, :type, :hashing_url]
end

defmodule DevRandom.Platforms.Post do
  @enforce_keys [:attachments]
  defstruct [:attachments, :text, :cleanup_data]
end

defmodule DevRandom.Platforms.PostSource do
  @callback post() :: DevRandom.Platforms.Post
  @callback cleanup(DevRandom.Platforms.Post) :: :ok | {:error, term}
end
