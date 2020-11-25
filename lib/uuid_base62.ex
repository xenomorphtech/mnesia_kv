defmodule MnesiaKV.Uuid do
  @base62_alphabet String.split(
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    ~r{},
    trim: true
  )

  defp int_to_base62(0), do: ""

  defp int_to_base62(num) do
    quot = div(num, 62)
    rem = rem(num, 62)
    char = Enum.at(@base62_alphabet, rem)
    int_to_base62(quot) <> char
  end

  def generate(random_bytes \\ 4) do
    rng_bytes = :crypto.strong_rand_bytes(random_bytes)
    time_6 = :binary.encode_unsigned(:os.system_time(1000))
    rng = time_6 <> rng_bytes
    int_to_base62(:binary.decode_unsigned(rng))
  end
end
