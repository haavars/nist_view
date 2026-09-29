defmodule NistView.PhantomFixtureTest do
  @moduledoc """
  Parses a transaction written by phantom's record builders (see
  test/fixtures/README.md): a producer this project's code never touched.
  """

  use ExUnit.Case, async: true

  alias NistView.{Imaging, Parser, Record}

  setup_all do
    {:ok, file} = Parser.parse(File.read!("test/fixtures/phantom_enrol.an2"))
    %{nist: file}
  end

  test "parses every record with no warnings", %{nist: file} do
    assert file.warnings == []

    assert Enum.map(file.records, &{&1.type, &1.idc}) == [
             {1, nil},
             {2, 0},
             {10, 1},
             {14, 2},
             {14, 3},
             {15, 4}
           ]

    [type1 | _] = file.records
    assert Record.value(type1, 2) == "0502"
    assert Record.field(type1, 13).subfields == [["PHANTOM", "1"]]
  end

  test "describes each image", %{nist: file} do
    images = for %Record{type: type, image: image} <- file.records, image, do: {type, image}

    assert [
             {10, %{compression: :png, width: 96, height: 120, ppi: nil, colorspace: "SRGB"}},
             {14, %{compression: :png, width: 128, height: 96, ppi: 500, bit_depth: 8}},
             {14, %{compression: :wsq, label: "WSQ20", ppi: 500}},
             {15, %{compression: :wsq, label: "WSQ20", ppi: 500}}
           ] = images

    for {_type, image} <- images do
      assert {:ok, _mime, _bytes} = Imaging.displayable(image)
    end
  end

  test "keeps phantom's non-standard 901 field", %{nist: file} do
    for record <- file.records, record.type in [14, 15] do
      assert Record.value(record, 901) == "2"
    end
  end
end
