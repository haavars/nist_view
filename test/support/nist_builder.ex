defmodule NistView.NistBuilder do
  @moduledoc """
  Builds synthetic ANSI/NIST-ITL transactions for tests.
  """

  @fs <<0x1C>>
  @gs <<0x1D>>
  @rs <<0x1E>>
  @us <<0x1F>>

  def rs, do: @rs
  def us, do: @us

  @doc """
  Builds a tagged record from `fields` (`[{number, iodata}]`, without
  field 001), computing the self-inclusive LEN.
  """
  def tagged(type, fields) do
    type_str = Integer.to_string(type)

    body =
      fields
      |> Enum.map(fn {number, value} -> [type_str, ".", pad(number), ":", value] end)
      |> Enum.intersperse(@gs)
      |> then(&IO.iodata_to_binary([&1, @fs]))

    prefix = byte_size(type_str) + byte_size(".001:") + byte_size(@gs)
    len = find_len(prefix + byte_size(body), 1)

    IO.iodata_to_binary([type_str, ".001:", Integer.to_string(len), @gs, body])
  end

  defp find_len(rest, digits) do
    total = rest + digits
    if length(Integer.digits(total)) == digits, do: total, else: find_len(rest, digits + 1)
  end

  @doc "Builds a binary Type-4 record."
  def type4(idc, opts \\ []) do
    data = Keyword.get(opts, :data, <<>>)
    fgp = Keyword.get(opts, :fgp, [1])
    fgp_bytes = for p <- fgp ++ List.duplicate(255, 6 - length(fgp)), into: <<>>, do: <<p>>

    <<18 + byte_size(data)::32, idc, Keyword.get(opts, :imp, 1), fgp_bytes::binary,
      Keyword.get(opts, :isr, 0), Keyword.get(opts, :hll, 0)::16, Keyword.get(opts, :vll, 0)::16,
      Keyword.get(opts, :gca, 1), data::binary>>
  end

  @doc """
  Builds a transaction: a Type-1 whose CNT lists `records`
  (`[{type, idc, bytes}]`), followed by the records.
  """
  def transaction(records, type1_fields \\ []) do
    cnt =
      [
        ["1", @us, Integer.to_string(length(records))]
        | Enum.map(records, fn {type, idc, _} ->
            [Integer.to_string(type), @us, Integer.to_string(idc)]
          end)
      ]
      |> Enum.intersperse(@rs)

    defaults = [
      {2, "0502"},
      {3, cnt},
      {4, "TEST"},
      {5, "20260929"},
      {7, "DAI"},
      {8, "ORI"},
      {9, "TCN1"},
      {11, "19.69"},
      {12, "19.69"}
    ]

    fields =
      defaults
      |> Enum.reject(fn {number, _} -> List.keymember?(type1_fields, number, 0) end)
      |> Kernel.++(type1_fields)
      |> Enum.sort_by(&elem(&1, 0))

    IO.iodata_to_binary([tagged(1, fields) | Enum.map(records, &elem(&1, 2))])
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")
end
