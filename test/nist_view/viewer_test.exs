defmodule NistView.ViewerTest do
  use ExUnit.Case, async: true

  alias NistView.{ImageRef, Parser, Record, Viewer}

  setup_all do
    {:ok, file} = Parser.parse(File.read!("test/fixtures/phantom_enrol.an2"))
    %{nist: file}
  end

  test "summarises Type-1", %{nist: file} do
    assert %{
             version: "0502",
             tot: "ENROL",
             date: "2026-09-29",
             tcn: "PH-TEST-0001-ENROL",
             domain: "PHANTOM 1"
           } =
             Viewer.summary(file)
  end

  test "titles records by position or kind", %{nist: file} do
    assert Enum.map(file.records, &Viewer.title/1) == [
             "Transaction information",
             "User-defined descriptive text",
             "Face",
             "Right thumb",
             "Left and right thumbs",
             "Right writer's palm"
           ]
  end

  test "describes images, noting a wrong label" do
    record = %Record{
      type: 14,
      image: %ImageRef{
        compression: :jpegl,
        format: :jpegb,
        label: "JPEGL",
        width: 10,
        height: 20,
        ppi: 500
      }
    }

    assert Viewer.image_summary(record) == "JPEG (labelled JPEGL) · 10×20 · 500 ppi"
    assert Viewer.image_summary(%Record{type: 2}) == nil
  end

  test "maps tenprint positions to records", %{nist: file} do
    assert Viewer.tenprint(file) == %{1 => 3, 15 => 4}
  end

  test "has no minutiae for records without a Type-9", %{nist: file} do
    assert Viewer.minutiae_for(file, 3) == []
    assert Viewer.minutiae_for(file, 0) == []
  end

  test "formats hex lines" do
    assert [{16, hex, "ABCDEFGHIJKLMNOP"}, {32, "0A 00", ".."}] =
             Viewer.hex_lines("ABCDEFGHIJKLMNOP" <> <<10, 0>>, 16)

    assert hex == "41 42 43 44 45 46 47 48  49 4A 4B 4C 4D 4E 4F 50"
    assert Viewer.hex_lines(<<>>) == []
  end

  test "describes parser problems in plain language" do
    assert Viewer.describe({:truncated, 100, 10}) ==
             "the record declares 100 bytes but only 10 remain"

    assert Viewer.describe(:invalid_wsq) == "the image data is invalid or corrupt"
    assert Viewer.describe(:something_new) == ":something_new"
    assert Viewer.describe({:something, <<1, 2, 3>>}) == "unexpected error"
  end

  test "describes a crash while rendering without the pixels in it" do
    pixels = :binary.copy(<<130, 121, 118>>, 1000)
    undef = {:undef, [{NistView.Codecs, :encode_png, [pixels, 3300, 4400, 3], []}]}

    assert Viewer.describe_exit(undef) ==
             "internal error (undef in NistView.Codecs.encode_png/4)"

    match = {%MatchError{term: pixels}, [{NistView.Imaging, :displayable, 1, []}]}

    assert Viewer.describe_exit(match) ==
             "internal error (MatchError in NistView.Imaging.displayable/1)"

    assert Viewer.describe_exit(:killed) == "internal error (killed)"
    assert Viewer.describe_exit({:shutdown, pixels}) == "internal error"
  end
end
