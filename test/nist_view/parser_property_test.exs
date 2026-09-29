defmodule NistView.ParserPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import NistView.NistBuilder

  alias NistView.{NistFile, Parser, Record}

  # -- Generators ---------------------------------------------------------------

  # Printable ASCII never contains a separator.
  defp item, do: string(:ascii, max_length: 12)

  defp text_value do
    gen all(
          subfields <-
            list_of(list_of(item(), min_length: 1, max_length: 4), min_length: 1, max_length: 4)
        ) do
      subfields
    end
  end

  defp tagged_record do
    gen all(
          type <- member_of([2, 10, 13, 14, 15, 17]),
          numbers <- uniq_list_of(integer(3..998), max_length: 6),
          values <- list_of(text_value(), length: length(numbers)),
          data <- one_of([constant(nil), binary(max_length: 200)])
        ) do
      fields = Enum.zip(Enum.sort(numbers), values)
      {type, fields, data}
    end
  end

  defp type4_record do
    gen all(
          fgp <- list_of(integer(0..254), min_length: 1, max_length: 6),
          hll <- integer(0..65_535),
          vll <- integer(0..65_535),
          gca <- integer(0..255),
          data <- binary(max_length: 200)
        ) do
      {4, %{fgp: fgp, hll: hll, vll: vll, gca: gca}, data}
    end
  end

  # A transaction with IDCs 0, 1, ... and the records it should parse into.
  defp transaction_gen do
    gen all(specs <- list_of(one_of([tagged_record(), type4_record()]), max_length: 5)) do
      specs = Enum.with_index(specs)
      data = transaction(Enum.map(specs, &encode/1))
      {data, specs}
    end
  end

  defp encode({{4, header, data}, idc}) do
    {4, idc,
     type4(idc, fgp: header.fgp, hll: header.hll, vll: header.vll, gca: header.gca, data: data)}
  end

  defp encode({{type, fields, data}, idc}) do
    text = Enum.map(fields, fn {n, subfields} -> {n, join(subfields)} end)
    binary = if data, do: [{999, data}], else: []
    {type, idc, tagged(type, [{2, Integer.to_string(idc)} | text] ++ binary)}
  end

  defp join(subfields), do: subfields |> Enum.map(&Enum.join(&1, us())) |> Enum.join(rs())

  # -- Properties ---------------------------------------------------------------

  property "generated transactions parse back to what was written" do
    check all({data, specs} <- transaction_gen(), max_runs: 300) do
      assert {:ok, %NistFile{warnings: [], records: [_type1 | records]}} = Parser.parse(data)
      assert length(records) == length(specs)

      for {record, {spec, idc}} <- Enum.zip(records, specs) do
        assert record.idc == idc
        assert_record(record, spec)
      end

      # The records cover the file exactly.
      last = List.last(records)
      if last, do: assert(last.offset + last.length == byte_size(data))
    end
  end

  property "truncated or corrupted transactions never raise" do
    check all(
            {data, _specs} <- transaction_gen(),
            cut <- integer(0..byte_size(data)),
            pos <- integer(0..max(byte_size(data) - 1, 0)),
            byte <- integer(0..255),
            max_runs: 500
          ) do
      assert_total(binary_part(data, 0, cut))

      <<before::binary-size(pos), _, rest::binary>> = data
      assert_total(<<before::binary, byte, rest::binary>>)
    end
  end

  property "arbitrary bytes never raise" do
    check all(data <- binary(max_length: 300), max_runs: 500) do
      assert_total(data)
      assert_total("1.001:" <> data)
    end
  end

  defp assert_record(%Record{type: 4} = record, {4, header, data}) do
    assert record.encoding == :binary
    assert Record.field(record, 4).subfields == [Enum.map(header.fgp, &Integer.to_string/1)]
    assert {record.image.width, record.image.height} == {header.hll, header.vll}
    assert Record.value(record, 8) == Integer.to_string(header.gca)
    assert record.image.data == data
  end

  defp assert_record(%Record{} = record, {type, fields, data}) do
    assert record.type == type
    assert record.encoding == :tagged

    for {number, subfields} <- fields do
      assert Record.field(record, number).subfields == subfields
    end

    if data,
      do: assert(Record.value(record, 999) == data),
      else: refute(Record.field(record, 999))
  end

  defp assert_total(data) do
    case Parser.parse(data) do
      {:ok, %NistFile{}} -> :ok
      {:error, {offset, _}, %NistFile{}} when is_integer(offset) -> :ok
    end
  end
end
