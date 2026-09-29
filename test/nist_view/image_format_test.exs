defmodule NistView.ImageFormatTest do
  use ExUnit.Case, async: true

  alias NistView.ImageFormat

  test "recognises each signature" do
    assert ImageFormat.detect(File.read!("test/fixtures/synthetic.wsq")) == :wsq
    assert ImageFormat.detect(File.read!("test/fixtures/synthetic_grey.jpl")) == :jpegl
    assert ImageFormat.detect(File.read!("test/fixtures/synthetic_grey.jp2")) == :jp2
    assert ImageFormat.detect(File.read!("test/fixtures/synthetic_rgb.j2k")) == :jp2
    assert ImageFormat.detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0>>) == :png
  end

  test "tells JPEG frame types apart after other segments" do
    app0 = <<0xFF, 0xE0, 0, 4, 0, 0>>

    assert ImageFormat.detect(<<0xFF, 0xD8, app0::binary, 0xFF, 0xC0, 0, 2>>) == :jpegb
    assert ImageFormat.detect(<<0xFF, 0xD8, app0::binary, 0xFF, 0xC2, 0, 2>>) == :jpegb
    assert ImageFormat.detect(<<0xFF, 0xD8, app0::binary, 0xFF, 0xC3, 0, 2>>) == :jpegl
    assert ImageFormat.detect(<<0xFF, 0xD8, 0xFF, 0xC4, 0, 2, 0xFF, 0xC3>>) == :jpegl
    assert ImageFormat.detect(<<0xFF, 0xD8, app0::binary, 0xFF, 0xC9, 0, 2>>) == :unknown
  end

  test "returns nil for unrecognised or truncated data" do
    assert ImageFormat.detect(<<>>) == nil
    assert ImageFormat.detect("hello") == nil
    assert ImageFormat.detect(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 40>>) == nil
    assert ImageFormat.detect(<<0xFF, 0xD8, 0xFF, 0xDA, 0, 2>>) == nil
  end
end
