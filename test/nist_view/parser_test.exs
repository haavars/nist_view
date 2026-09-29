defmodule NistView.ParserTest do
  use ExUnit.Case, async: true

  import NistView.NistBuilder

  alias NistView.{Field, Parser, Record}

  # Image bytes that contain every separator and a colon.
  @awkward_data <<0xFF, 0xA0, 0x1C, 0x1D, 0x1E, 0x1F, ?:, 0x1C, 0x00, 0x1C>>

  defp type2(idc, extra \\ []), do: tagged(2, [{2, Integer.to_string(idc)} | extra])

  defp type14(idc, opts \\ []) do
    tagged(14, [
      {2, Integer.to_string(idc)},
      {3, "1"},
      {4, "SRC"},
      {5, "20260929"},
      {6, "804"},
      {7, "1000"},
      {8, Keyword.get(opts, :slc, "1")},
      {9, Keyword.get(opts, :thps, "500")},
      {10, "500"},
      {11, Keyword.get(opts, :cga, "WSQ20")},
      {12, "8"},
      {13, "1"},
      {999, Keyword.get(opts, :data, @awkward_data)}
    ])
  end

  describe "tagged records" do
    test "parses Type-1 and Type-2 fields, splitting subfields and items" do
      data = transaction([{2, 0, type2(0, [{3, "a" <> us() <> "b" <> rs() <> "c"}])}])

      assert {:ok, file} = Parser.parse(data)
      assert file.size == byte_size(data)
      assert file.warnings == []
      assert [%Record{type: 1, idc: nil} = type1, %Record{type: 2, idc: 0} = type2] = file.records

      assert Record.value(type1, 2) == "0502"
      assert %Field{subfields: [["1", "1"], ["2", "0"]]} = Record.field(type1, 3)
      assert %Field{subfields: [["a", "b"], ["c"]]} = Record.field(type2, 3)
      assert type2.offset == type1.length
      assert type2.offset + type2.length == byte_size(data)
    end

    test "slices field 999 by length even when it contains separators" do
      data = transaction([{14, 1, type14(1)}])

      assert {:ok, %{records: [_, type14]}} = Parser.parse(data)
      assert %Field{value: @awkward_data, subfields: nil} = Record.field(type14, 999)
    end

    test "describes the image, keeping its data as a sub-binary of the input" do
      # Large enough to be a reference-counted binary; small ones are always copied.
      image_data = :binary.copy(@awkward_data, 100)
      data = transaction([{14, 1, type14(1, data: image_data)}])

      assert {:ok, %{records: [_, %Record{image: image}]}} = Parser.parse(data)
      assert image.compression == :wsq
      assert image.label == "WSQ20"
      assert {image.width, image.height, image.ppi, image.bit_depth} == {804, 1000, 500, 8}
      assert image.data == image_data
      assert :binary.referenced_byte_size(image.data) == byte_size(data)
    end

    test "converts pixels per centimetre to ppi" do
      data = transaction([{14, 1, type14(1, slc: "2", thps: "197")}])

      assert {:ok, %{records: [_, %Record{image: %{ppi: 500}}]}} = Parser.parse(data)
    end

    test "detects the data's real format, except for uncompressed images" do
      wsq = File.read!("test/fixtures/synthetic.wsq")

      data = transaction([{14, 1, type14(1, cga: "JPEGB", data: wsq)}])
      assert {:ok, %{records: [_, %Record{image: image}]}} = Parser.parse(data)
      assert {image.compression, image.format} == {:jpegb, :wsq}

      data = transaction([{14, 1, type14(1, cga: "NONE", data: wsq)}])
      assert {:ok, %{records: [_, %Record{image: %{format: :raw}}]}} = Parser.parse(data)
    end

    test "normalises compression labels and keeps unknown ones" do
      for {label, expected} <- [
            {"WSQ", :wsq},
            {"WSQ20", :wsq},
            {"jpegb", :jpegb},
            {"NONE", :raw},
            {"JP2L", :jp2l},
            {"XYZ", :unknown}
          ] do
        data = transaction([{14, 1, type14(1, cga: label)}])
        assert {:ok, %{records: [_, %Record{image: image}]}} = Parser.parse(data)
        assert {image.compression, image.label} == {expected, label}
      end
    end
  end

  describe "binary records" do
    test "parses Type-4 records scheduled by CNT" do
      t4 = type4(1, fgp: [13, 14], imp: 3, hll: 1600, vll: 1000, gca: 1, data: @awkward_data)
      data = transaction([{2, 0, type2(0)}, {4, 1, t4}])

      assert {:ok, %{records: [_, _, type4], warnings: []}} = Parser.parse(data)
      assert %Record{type: 4, idc: 1, encoding: :binary, length: 28} = type4

      assert Enum.map(type4.fields, &{&1.number, &1.value}) == [
               {1, "28"},
               {2, "1"},
               {3, "3"},
               {4, "13" <> us() <> "14"},
               {5, "0"},
               {6, "1600"},
               {7, "1000"},
               {8, "1"},
               {9, @awkward_data}
             ]

      assert %{compression: :wsq, label: "1", width: 1600, height: 1000, ppi: 500} = type4.image
    end

    test "takes the native scanning resolution from Type-1 when ISR is 1" do
      data = transaction([{4, 1, type4(1, isr: 1)}], [{11, "39.37"}])

      assert {:ok, %{records: [_, %Record{image: %{ppi: 1000}}]}} = Parser.parse(data)
    end

    test "keeps a binary record too short for its header, with a warning" do
      short = <<5::32, 1>>
      data = transaction([{4, 1, short}, {2, 0, type2(0)}])

      assert {:ok, %{records: [_, type4, _], warnings: [{offset, :short_record}]}} =
               Parser.parse(data)

      assert type4.offset == offset
      assert type4.image == nil
    end
  end

  describe "malformed input" do
    test "returns the records parsed before a truncated record" do
      data = transaction([{2, 0, type2(0)}, {14, 1, type14(1)}])
      cut = binary_part(data, 0, byte_size(data) - 3)

      assert {:error, {offset, {:truncated, _, _}}, file} = Parser.parse(cut)
      assert [%Record{type: 1}, %Record{type: 2} = type2] = file.records
      assert offset == type2.offset + type2.length
    end

    test "reports records that CNT announces but the file lacks" do
      full = transaction([{2, 0, type2(0)}, {2, 1, type2(1)}])
      {:ok, %{records: [_, _, last]}} = Parser.parse(full)
      data = binary_part(full, 0, last.offset)

      assert {:error, {offset, {:missing_records, 1}}, %{records: [_, _]}} = Parser.parse(data)
      assert offset == last.offset
    end

    test "falls back to tag-only parsing when CNT is unusable" do
      data = transaction([{2, 0, type2(0)}], [{3, "garbage"}])

      assert {:ok, %{records: [_, %Record{type: 2}], warnings: [{0, :unusable_cnt}]}} =
               Parser.parse(data)
    end

    test "warns when a record's type or IDC differs from CNT" do
      data = transaction([{10, 0, type2(0)}, {2, 5, type2(1)}])

      assert {:ok, %{warnings: warnings}} = Parser.parse(data)
      assert [{_, {:type_mismatch, 10, 2}}, {_, {:idc_mismatch, 5, 1}}] = warnings
    end

    test "warns about bytes after the last scheduled record" do
      data = transaction([{2, 0, type2(0)}]) <> "\r\n"

      assert {:ok, %{warnings: [{_, {:trailing_bytes, 2}}]}} = Parser.parse(data)
    end

    test "keeps the fields before a malformed one and carries on" do
      bad = tagged(2, [{2, "0"}, {3, "ok"}]) |> String.replace("2.003:", "2.X03:")
      data = transaction([{2, 0, bad}, {2, 1, type2(1)}])

      assert {:ok, %{records: [_, first, second], warnings: [{_, :malformed_field}]}} =
               Parser.parse(data)

      assert Enum.map(first.fields, & &1.number) == [1, 2]
      assert second.idc == 1
    end

    test "rejects a file that does not start with Type-1" do
      assert {:error, {0, {:first_record_not_type_1, 2}}, %{records: []}} =
               Parser.parse(type2(0))
    end

    test "rejects data that is not a NIST file" do
      assert {:error, {0, :bad_record_header}, %{records: []}} = Parser.parse("hello world")
      assert {:error, {0, :bad_record_header}, _} = Parser.parse(<<>>)
    end

    test "never raises on a truncated or corrupted file" do
      data =
        transaction([
          {2, 0, type2(0)},
          {4, 1, type4(1, hll: 2, vll: 2, data: <<1, 2, 3, 4>>)},
          {14, 2, type14(2)}
        ])

      for size <- 0..byte_size(data) do
        assert_parses(binary_part(data, 0, size))
      end

      for pos <- 0..(byte_size(data) - 1), byte <- [0x00, 0x1C, 0x1D, 0x3A, 0xFF] do
        <<before::binary-size(pos), _, rest::binary>> = data
        assert_parses(<<before::binary, byte, rest::binary>>)
      end
    end
  end

  defp assert_parses(data) do
    case Parser.parse(data) do
      {:ok, %NistView.NistFile{}} -> :ok
      {:error, {offset, _reason}, %NistView.NistFile{}} when is_integer(offset) -> :ok
    end
  end
end
