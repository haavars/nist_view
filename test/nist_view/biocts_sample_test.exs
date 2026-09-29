defmodule NistView.BioctsSampleTest do
  @moduledoc """
  Parses NIST's BioCTS sample transactions: files produced outside this
  project. Fetch them with `mix nist.samples`; skipped when missing.
  """

  use ExUnit.Case, async: true

  alias NistView.{Field, Imaging, Minutiae, Parser, Record}

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

  test "M1, legacy and FBI blocks for the same print agree after normalisation" do
    [m1, standard, fbi] =
      for name <- ~w(pass-type-9-14-m1.an2 pass-type-9-10-14.an2 pass-type-9-4-iafis.an2) do
        type9 = name |> parse!() |> Map.fetch!(:records) |> Enum.find(&(&1.type == 9))
        assert [set] = Minutiae.decode(type9)
        # All three prints are 800 × 768 at 197 pixels per centimetre.
        Minutiae.to_pixels(set, 197 * 2.54, 768)
      end

    assert {m1.format, standard.format, fbi.format} == {:m1, :standard, :fbi}

    for other <- [standard, fbi] do
      assert length(other.minutiae) == 48

      for {a, b} <- Enum.zip(m1.minutiae, other.minutiae) do
        assert_in_delta a.x, b.x, 1.0
        assert_in_delta a.y, b.y, 1.0
        assert abs(rem(round(a.angle - b.angle) + 540, 360) - 180) <= 1
      end

      for {a, b} <- Enum.zip(m1.cores ++ m1.deltas, other.cores ++ other.deltas) do
        assert_in_delta a.x, b.x, 1.0
        assert_in_delta a.y, b.y, 1.0
      end
    end
  end

  # SHA-256 of NBIS 5.0.0 `dwsq -raw_out` output for these images. All 47
  # distinct WSQ images in the set were compared bit for bit on 2026-09-29.
  @dwsq_sha256 [
    {"pass-type-4-tpcard.an2", 1,
     "2f90d78455d8e23dc2975688d085fba70a067995d5b0a725a57ba6996d7e35dd"},
    {"pass-type-14-mandatory-only.an2", 0,
     "68d14981dcea908214713affbd423840ba089dfb574d194bd0a4f356cff74f6a"}
  ]

  test "WSQ decoding is bit-identical to NBIS dwsq" do
    for {name, idc, sha} <- @dwsq_sha256 do
      record =
        name |> parse!() |> Map.fetch!(:records) |> Enum.find(&(&1.idc == idc and &1.image))

      assert {:ok, %{pixels: pixels}} = Imaging.decode(record.image)
      assert Base.encode16(:crypto.hash(:sha256, pixels), case: :lower) == sha, name
    end
  end

  # SHA-256 of OpenJPEG 2.5.4 `opj_decompress` output. All 12 distinct
  # JPEG 2000 images in the set were compared bit for bit on 2026-09-29.
  @opj_sha256 [
    {"pass-type-15-palms.an2", 2,
     "4454c09c35143902ef9958e61af8b5657a099a95ee37ff679fdccac984c7597c"},
    {"pass-type-10-scar-face-sap50-addedRequiredInfoItems.an2", 2,
     "ca4359ab687106d696a1a635531b3ecb2611e87bb47bb37d1d42c8b4d0f1d7fc"}
  ]

  test "JPEG 2000 decoding is bit-identical to OpenJPEG opj_decompress" do
    for {name, idc, sha} <- @opj_sha256 do
      record =
        name
        |> parse!()
        |> Map.fetch!(:records)
        |> Enum.find(&((&1.idc == idc and &1.image) && &1.image.format in [:jp2, :jp2l]))

      assert {:ok, %{pixels: pixels}} = Imaging.decode(record.image)
      assert Base.encode16(:crypto.hash(:sha256, pixels), case: :lower) == sha, name
    end
  end

  test "every image in every file is displayable" do
    for name <- File.ls!(@dir),
        {_, file} = parse_any(name),
        %Record{image: image} = record <- file.records,
        image do
      assert {:ok, _mime, _bytes} = Imaging.displayable(image),
             "#{name} Type-#{record.type} IDC #{record.idc} (#{image.label})"
    end
  end

  test "images whose label disagrees with their data are decoded by their data" do
    file = parse!("pass-type-10-14-17-piv-index-iris-replacedCorruptImages_fixedAspectRatio.an2")

    mislabelled = for %Record{image: %{compression: :jpegl} = image} <- file.records, do: image
    assert [_, _] = mislabelled
    assert Enum.all?(mislabelled, &(&1.format == :jpegb))
  end

  defp parse_any(name) do
    case Parser.parse(File.read!(Path.join(@dir, name))) do
      {:ok, file} -> {:ok, file}
      {:error, _error, file} -> {:error, file}
    end
  end
end
