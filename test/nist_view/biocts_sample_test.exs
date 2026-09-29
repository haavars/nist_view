defmodule NistView.BioctsSampleTest do
  @moduledoc """
  Parses NIST's BioCTS sample transactions: files produced outside this
  project. Fetch them with `mix nist.samples`; skipped when missing.
  """

  use ExUnit.Case, async: true

  alias NistView.{Field, Imaging, Parser, Record}

  @dir "test/samples/biocts"

  @moduletag skip: if(File.dir?(@dir), do: false, else: "#{@dir} missing; run `mix nist.samples`")

  defp parse!(name) do
    assert {:ok, file} = Parser.parse(File.read!(Path.join(@dir, name)))
    file
  end

  defp images(file), do: for(%Record{image: image} <- file.records, image, do: image)

  test "every pass-* file parses completely" do
    files = @dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "pass-"))
    assert length(files) > 50

    for name <- files do
      assert {:ok, file} = Parser.parse(File.read!(Path.join(@dir, name))), name
      assert [%Record{type: 1} | _] = file.records
    end
  end

  test "pass-type-4-tpcard.an2: fourteen legacy Type-4 WSQ records, all decodable" do
    file = parse!("pass-type-4-tpcard.an2")

    assert [%Record{type: 1}, %Record{type: 2} | type4s] = file.records
    assert length(type4s) == 14
    assert Enum.all?(type4s, &match?(%Record{type: 4, encoding: :binary}, &1))
    assert Enum.map(type4s, & &1.idc) == Enum.to_list(1..14)
    assert Enum.map(type4s, &Record.value(&1, 4)) == ~w(1 2 3 4 5 6 7 8 9 10 14 12 11 13)

    [thumb | _] = type4s
    assert %{compression: :wsq, width: 804, height: 752, ppi: 500} = thumb.image
    assert {:ok, %{width: 804, height: 752, ppi: 500}} = Imaging.decode(thumb.image)

    for record <- type4s do
      assert {:ok, "image/png", _} = Imaging.displayable(record.image)
    end
  end

  test "pass-type-14-mandatory-only.an2: WSQ20 payload sliced exactly" do
    bytes = File.read!(Path.join(@dir, "pass-type-14-mandatory-only.an2"))
    assert {:ok, %{records: [_, type14]}} = Parser.parse(bytes)

    assert %{compression: :wsq, label: "WSQ20", width: 804, height: 1000} = type14.image
    %Field{value: data} = Record.field(type14, 999)

    # The payload ends right before the record's final FS.
    assert binary_part(
             bytes,
             type14.offset + type14.length - 1 - byte_size(data),
             byte_size(data)
           ) == data

    assert <<0xFF, 0xA0, _::binary>> = data
  end

  test "pass-type-9-14-m1.an2: INCITS 378 (M1) minutiae fields" do
    file = parse!("pass-type-9-14-m1.an2")
    type9 = Enum.find(file.records, &(&1.type == 9))

    for number <- [126, 128, 129, 134, 136, 137] do
      assert Record.field(type9, number), "9.#{number} missing"
    end
  end

  test "pass-all-supported-types.an2: EFS minutiae and every image record" do
    file = parse!("pass-all-supported-types.an2")

    assert Enum.map(file.records, & &1.type) ==
             [1, 2, 4, 7, 8, 9, 10, 13, 14, 15, 16, 17, 18, 19, 20, 20, 21, 21, 98, 99]

    type9 = Enum.find(file.records, &(&1.type == 9))
    assert Record.field(type9, 300)

    for image <- images(file), image.compression in [:wsq, :png, :jpegb, :raw] do
      assert {:ok, _mime, _bytes} = Imaging.displayable(image)
    end
  end

  test "pass-type-9-4-iafis.an2: uncompressed Type-4 (GCA 0)" do
    file = parse!("pass-type-9-4-iafis.an2")
    [image] = images(file)

    assert %{compression: :raw, width: 800, height: 768} = image
    assert byte_size(image.data) == 800 * 768
    assert {:ok, "image/png", _} = Imaging.displayable(image)
  end

  test "fail-deprecated-records.an2: header-less Type-3/5/6 records are kept with warnings" do
    file = parse!("fail-deprecated-records.an2")

    assert Enum.map(file.records, & &1.type) == [1, 3, 5, 6]
    assert Enum.map(file.warnings, &elem(&1, 1)) == List.duplicate(:short_record, 3)
  end
end
