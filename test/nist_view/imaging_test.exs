defmodule NistView.ImagingTest do
  use ExUnit.Case, async: true

  alias NistView.{ImageRef, Imaging}

  @jp2 %ImageRef{
    compression: :jp2,
    format: :jp2,
    label: "JP2",
    width: 128,
    height: 96,
    data: File.read!("test/fixtures/synthetic_grey.jp2")
  }

  @wsq %ImageRef{
    compression: :wsq,
    format: :wsq,
    label: "WSQ20",
    width: 128,
    height: 96,
    data: File.read!("test/fixtures/synthetic.wsq")
  }

  test "only JPEG 2000 at least twice the target size gets a preview" do
    assert Imaging.previewable?(@jp2, {64, 48})
    refute Imaging.previewable?(@jp2, {65, 48})
    assert Imaging.previewable?(%{@jp2 | width: nil, height: nil}, {800, 800})
    refute Imaging.previewable?(@wsq, {32, 24})
  end

  test "a preview is a smaller PNG that says the full size" do
    assert {:preview, "image/png", png, {128, 96}} = Imaging.preview(@jp2, {32, 24})
    assert <<0x89, "PNG", _::binary>> = png
    assert {:ok, "image/png", full} = Imaging.displayable(@jp2)
    assert byte_size(png) < byte_size(full)
  end

  test "an image that cannot be reduced comes whole" do
    assert {:ok, "image/png", _} = Imaging.preview(@jp2, {128, 96})
    assert {:ok, "image/png", _} = Imaging.preview(@wsq, {32, 24})
  end
end
