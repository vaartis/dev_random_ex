defmodule DevRandom.Platforms.VK.Fuse do
  def start do
    ExternalService.start(
      __MODULE__,
      rate_limit: {3, 1_000},
      fuse_strategy: {:standard, 5, 60_000 * 5},
      fuse_refresh: 5_000
    )
  end
end

defmodule DevRandom.Platforms.OldDanbooru.Fuse do
  def start do
    ExternalService.start(
      __MODULE__,
      fuse_strategy: {:standard, 5, 60_000 * 5},
      fuse_refresh: 5_000
    )
  end
end
