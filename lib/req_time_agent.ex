defmodule DevRandom.RequestTimeAgent do
  use Agent
  use Timex

  def start_link(_args) do
    Agent.start_link(fn -> %{time: nil, number: 0} end, name: __MODULE__)
  end

  @doc """
  This function should be called before the request, to measure
  if it's safe to make one now (no more then 3 per second) or wait.

  It might not work as intended but should do the job fine
  """
  def before_request() do
    agent = __MODULE__
    # Update the time to now if it's the first time
    Agent.update(agent, fn st -> if is_nil(st.time) do put_in(st.time, Timex.now) else st end end)

    time_diff = Timex.diff(
      Timex.now,
      Agent.get(agent, fn st -> st.time end),
      :duration
    ) |> Duration.to_milliseconds

    # That'd be the first request in this second
    if time_diff > 1000 do
      Agent.update(agent, fn st ->
        st |>
          put_in([:time], Timex.now) |>
          put_in([:number], 1)
      end)
    else
      # If we did 3 or less requests this second, then go for one more
      if Agent.get(agent, fn st -> st.number end) <= 3 do
        Agent.update(agent, fn st ->
          st |>
            put_in([:time], Timex.now) |>
            put_in([:number], st.number + 1)
        end)
      else
        # Else sleep for the rest of the second and make the request
        Process.sleep(1000 - round(time_diff))

        Agent.update(agent, fn st ->
          st |>
            put_in([:time], Timex.now) |>
            put_in([:number], 1)
        end)
      end
    end

    :ok
  end
end
