defmodule NistView.MinutiaeTest do
  use ExUnit.Case, async: true

  import NistView.NistBuilder

  alias NistView.{Minutiae, Parser, Record}

  defp items(list), do: Enum.join(list, us())
  defp subfields(list), do: list |> Enum.map(&items/1) |> Enum.join(rs())

  defp type9(fields) do
    data = transaction([{9, 1, tagged(9, [{2, "1"}, {3, "3"}, {4, "U"} | fields])}])
    {:ok, %{records: [_, record]}} = Parser.parse(data)
    record
  end

  test "decodes an M1 block, scaling its pixels to millimetres" do
    record =
      type9([
        {128, "800"},
        {129, "768"},
        {130, "1"},
        {131, "500"},
        {132, "500"},
        {136, "2"},
        {137, subfields([~w(1 500 250 45 1 80), ~w(2 100 50 0 2 60)])},
        {139, subfields([~w(300 200 10)])},
        {140, subfields([~w(400 600 0)])}
      ])

    assert [%Minutiae{format: :m1, units: :mm, origin: :top_left} = set] = Minutiae.decode(record)

    assert [first, second] = set.minutiae
    assert %{index: 1, angle: 90.0, type: :ridge_ending, type_code: "1", quality: 80} = first
    assert_in_delta first.x, 25.4, 1.0e-9
    assert_in_delta first.y, 12.7, 1.0e-9
    assert %{type: :bifurcation, angle: +0.0} = second

    assert [%{angle: 20.0} = core] = set.cores
    assert_in_delta core.x, 15.24, 1.0e-9
    assert [%{angle: +0.0}] = set.deltas
  end

  test "decodes the legacy standard block and flips its bottom-left origin" do
    record =
      type9([
        {5, items(["AFIS/FBI", "E", ""])},
        {8, "10002000"},
        {10, "1"},
        {12, subfields([["1", "25401270090", "0", "B", "33,4"]])}
      ])

    assert [%Minutiae{format: :standard, origin: :bottom_left} = set] = Minutiae.decode(record)
    assert [%{index: 1, x: 25.4, y: 12.7, angle: 270.0, type: :bifurcation}] = set.minutiae
    assert [%{x: 10.0, y: 20.0}] = set.cores

    pixels = Minutiae.to_pixels(set, 500, 768)
    assert %Minutiae{units: :px, origin: :top_left} = pixels
    assert [%{x: x, y: y}] = pixels.minutiae
    assert_in_delta x, 500.0, 1.0e-9
    assert_in_delta y, 768 - 250.0, 1.0e-9
  end

  test "decodes the FBI/IAFIS block" do
    record =
      type9([
        {21, subfields([["10002000", "242", "0000"]])},
        {22, subfields([["30004000", "095"]])},
        {23, subfields([["001", "25401270281", "00", "A", "03304"]])}
      ])

    assert [%Minutiae{format: :fbi, origin: :top_left} = set] = Minutiae.decode(record)
    assert [%{index: 1, x: 25.4, y: 12.7, angle: 281.0, type: :ridge_ending}] = set.minutiae
    assert [%{x: 10.0, y: 20.0}] = set.cores
    assert [%{x: 30.0, y: 40.0}] = set.deltas
  end

  test "decodes an EFS block in abis_next's layout" do
    record =
      type9([
        {300, items(~w(4064 5080))},
        {302, "0"},
        {320, subfields([~w(1000 2000)])},
        {331, subfields([~w(2540 1270 45 E), ~w(100 200 400 X)])}
      ])

    assert [%Minutiae{format: :efs} = set] = Minutiae.decode(record)

    assert [%{x: 25.4, y: 12.7, angle: 45.0, type: :ridge_ending}, %{angle: 40.0, type: :other}] =
             set.minutiae

    assert [%{x: 10.0, y: 20.0}] = set.cores
  end

  test "returns one set per block, and none for a record without minutiae" do
    record =
      type9([
        {12, subfields([["1", "25401270090", "0", "A"]])},
        {331, subfields([~w(2540 1270 45 E)])}
      ])

    assert [%{format: :standard}, %{format: :efs}] = Minutiae.decode(record)
    assert Minutiae.decode(type9([{300, "1|1"}])) == []
    assert Minutiae.decode(%Record{type: 14}) == []
  end

  test "skips malformed entries" do
    record =
      type9([
        {130, "1"},
        {131, "500"},
        {137, subfields([~w(1 500 250 45 1 80), ~w(2 x 50 0 2 60), ~w(3 1)])}
      ])

    assert [%{minutiae: [%{index: 1}]}] = Minutiae.decode(record)
  end

  test "ignores an M1 block without a usable resolution" do
    assert Minutiae.decode(type9([{137, subfields([~w(1 500 250 45 1 80)])}])) == []
  end
end
