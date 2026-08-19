defmodule AiServiceElixir.UUID do
  @moduledoc """
  Minimal UUID v4. Elixir's stdlib has no UUID generator, so this is here
  rather than as a dependency -- Python's `uuid` is stdlib and needed no code.
  """

  @doc "A random UUID v4 string."
  def generate do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> format()
  end

  defp format(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
