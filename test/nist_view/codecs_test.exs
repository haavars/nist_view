defmodule NistView.CodecsTest do
  use ExUnit.Case, async: true

  alias NistView.{Codecs, Decoder, ImageRef, Imaging}

  @wsq File.read!("test/fixtures/synthetic.wsq")
  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  # The pattern in synthetic.wsq (see test/fixtures/README.md).
  defp expected_pixel(x, y), do: trunc(128 + 90 * :math.sin(x / 2.5) * :math.cos(y / 3.5))

  describe "Decoder.decode(:wsq, _)" do
    test "decodes the synthetic image close to its source pattern" do
      assert {:ok, decoded} = Decoder.decode(:wsq, @wsq)
      assert %{width: 128, height: 96, channels: 1, bit_depth: 8, ppi: 500} = decoded
      assert byte_size(decoded.pixels) == 128 * 96

      errors =
        for {pixel, i} <- Enum.with_index(:binary.bin_to_list(decoded.pixels)) do
          abs(pixel - expected_pixel(rem(i, 128), div(i, 128)))
        end

      # WSQ is lossy; at 2.25 bpp the pattern survives closely (mean error ~0.13).
      assert Enum.sum(errors) / length(errors) < 1
    end

    test "rejects data that is not WSQ" do
      assert {:error, :invalid_wsq} = Decoder.decode(:wsq, "not wsq")
      assert {:error, :invalid_wsq} = Decoder.decode(:wsq, <<>>)
    end

    test "rejects every truncation of a valid image without crashing" do
      for size <- 0..(byte_size(@wsq) - 1)//7 do
        assert {:error, _} = Decoder.decode(:wsq, binary_part(@wsq, 0, size))
      end
    end

    test "refuses images above the pixel limit before decoding" do
      # Frame header dimensions patched to 65535 × 65535.
      {pos, 2} = :binary.match(@wsq, <<0xFF, 0xA2>>)
      <<before::binary-size(pos + 6), _::32, rest::binary>> = @wsq

      assert {:error, :too_large} =
               Decoder.decode(:wsq, <<before::binary, 0xFFFF::16, 0xFFFF::16, rest::binary>>)
    end
  end

  defp fixture(name), do: File.read!(Path.join("test/fixtures", name))

  defp pattern(fun) do
    for y <- 0..95, x <- 0..127, into: <<>>, do: fun.(x, y)
  end

  defp ridges, do: pattern(&<<expected_pixel(&1, &2)>>)
  defp rgb, do: pattern(&<<rem(&1 * 2, 256), rem(&2 * 2, 256), rem(&1 + &2, 256)>>)

  describe "Decoder.decode(:jpegl, _)" do
    test "decodes greyscale exactly" do
      assert {:ok, decoded} = Decoder.decode(:jpegl, fixture("synthetic_grey.jpl"))
      assert %{width: 128, height: 96, channels: 1, ppi: 500, colorspace: :gray} = decoded
      assert decoded.pixels == ridges()
    end

    test "decodes interleaved RGB exactly" do
      assert {:ok, %{channels: 3, colorspace: :unspecified} = decoded} =
               Decoder.decode(:jpegl, fixture("synthetic_rgb.jpl"))

      assert decoded.pixels == rgb()
    end

    test "upsamples subsampled components by replication" do
      assert {:ok, %{width: 128, height: 96, channels: 3} = decoded} =
               Decoder.decode(:jpegl, fixture("synthetic_ycc420.jpl"))

      expected =
        pattern(fn x, y ->
          <<rem(x + 2 * y, 256), rem(64 + div(x, 2) * 2, 256),
            Integer.mod(200 - div(y, 2) * 2, 256)>>
        end)

      assert decoded.pixels == expected
    end

    test "rejects baseline JPEG and truncated data" do
      baseline = <<0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0>>
      assert {:error, :not_lossless_jpeg} = Decoder.decode(:jpegl, baseline)
      assert {:error, :invalid_jpegl} = Decoder.decode(:jpegl, "junk")

      data = fixture("synthetic_rgb.jpl")

      for size <- 0..(byte_size(data) - 1)//13 do
        assert {:error, _} = Decoder.decode(:jpegl, binary_part(data, 0, size))
      end
    end
  end

  describe "Decoder.decode(:jp2, _)" do
    test "decodes a lossless greyscale JP2 file exactly" do
      assert {:ok, %{width: 128, height: 96, channels: 1, colorspace: :gray} = decoded} =
               Decoder.decode(:jp2, fixture("synthetic_grey.jp2"))

      assert decoded.pixels == ridges()
    end

    test "decodes a raw RGB codestream exactly" do
      assert {:ok, %{channels: 3} = decoded} = Decoder.decode(:jp2, fixture("synthetic_rgb.j2k"))
      assert decoded.pixels == rgb()
    end

    test "scales 16-bit samples to 8 bits" do
      assert {:ok, %{channels: 1} = decoded} =
               Decoder.decode(:jp2, fixture("synthetic_grey16.jp2"))

      assert decoded.pixels == pattern(&<<div(rem(&1 * 512 + &2 * 7, 65_536) * 255, 65_535)>>)
    end

    test "rejects invalid and truncated data" do
      assert {:error, :invalid_jp2} = Decoder.decode(:jp2, "junk")

      data = fixture("synthetic_grey.jp2")

      for size <- 0..(byte_size(data) - 1)//11 do
        assert {:error, _} = Decoder.decode(:jp2, binary_part(data, 0, size))
      end
    end
  end

  describe "ycbcr_to_rgb/1" do
    test "converts full-range YCbCr" do
      assert {:ok, <<100, 100, 100, 254, 0, 0>>} =
               Codecs.ycbcr_to_rgb(<<100, 128, 128, 76, 85, 255>>)

      assert {:error, :invalid_dimensions} = Codecs.ycbcr_to_rgb(<<1, 2>>)
    end
  end

  describe "encode_png/4" do
    test "encodes greyscale and RGB pixels" do
      assert {:ok, <<@png_signature, _::binary>>} =
               Codecs.encode_png(<<0, 128, 255, 64>>, 2, 2, 1)

      assert {:ok, <<@png_signature, _::binary>>} =
               Codecs.encode_png(:binary.copy(<<1, 2, 3>>, 4), 2, 2, 3)
    end

    test "rejects pixel data that does not match the dimensions" do
      assert {:error, :invalid_dimensions} = Codecs.encode_png(<<1, 2, 3>>, 2, 2, 1)
      assert {:error, :invalid_dimensions} = Codecs.encode_png(<<>>, 0, 0, 1)
      assert {:error, :invalid_dimensions} = Codecs.encode_png(<<1, 2>>, 1, 1, 2)
    end
  end

  describe "Imaging.displayable/1" do
    test "converts WSQ to PNG" do
      image = %ImageRef{compression: :wsq, format: :wsq, label: "WSQ20", data: @wsq}
      assert {:ok, "image/png", <<@png_signature, _::binary>>} = Imaging.displayable(image)
    end

    test "converts uncompressed greyscale to PNG" do
      image = %ImageRef{
        compression: :raw,
        format: :raw,
        label: "NONE",
        width: 2,
        height: 2,
        bit_depth: 8,
        data: <<1, 2, 3, 4>>
      }

      assert {:ok, "image/png", <<@png_signature, _::binary>>} = Imaging.displayable(image)
    end

    test "passes PNG and JPEG through unchanged" do
      assert {:ok, "image/png", "png"} =
               Imaging.displayable(%ImageRef{
                 compression: :png,
                 format: :png,
                 label: "PNG",
                 data: "png"
               })

      assert {:ok, "image/jpeg", "jpg"} =
               Imaging.displayable(%ImageRef{
                 compression: :jpegb,
                 format: :jpegb,
                 label: "JPEGB",
                 data: "jpg"
               })
    end

    test "decodes JPEG 2000 and lossless JPEG to PNG" do
      for {format, name} <- [
            jp2: "synthetic_grey.jp2",
            jp2l: "synthetic_rgb.j2k",
            jpegl: "synthetic_rgb.jpl"
          ] do
        image = %ImageRef{compression: format, format: format, label: "", data: fixture(name)}
        assert {:ok, "image/png", <<@png_signature, _::binary>>} = Imaging.displayable(image)
      end
    end

    test "converts YCbCr to RGB when the record's colour space says so" do
      data = fixture("synthetic_ycc420.jpl")
      image = %ImageRef{compression: :jpegl, format: :jpegl, label: "JPEGL", data: data}

      assert {:ok, %{colorspace: :unspecified, pixels: ycc}} = Imaging.decode(image)

      assert {:ok, %{colorspace: :srgb, pixels: rgb}} =
               Imaging.decode(%{image | colorspace: "YCC"})

      assert {:ok, ^rgb} = Codecs.ycbcr_to_rgb(ycc)
    end

    test "follows the detected format rather than the label" do
      image = %ImageRef{compression: :jpegb, format: :wsq, label: "JPEGB", data: @wsq}
      assert {:ok, "image/png", _} = Imaging.displayable(image)
    end

    test "reports codecs that are not supported" do
      assert {:error, {:unsupported_compression, :unknown}} =
               Imaging.displayable(%ImageRef{
                 compression: :unknown,
                 format: :unknown,
                 label: "X",
                 data: <<>>
               })
    end

    test "rejects uncompressed data that does not fit its dimensions" do
      image = %ImageRef{
        compression: :raw,
        format: :raw,
        label: "NONE",
        width: 2,
        height: 2,
        bit_depth: 8,
        data: <<1, 2, 3>>
      }

      assert {:error, {:unsupported_raw_layout, 3, 2, 2, 8}} = Imaging.displayable(image)
    end
  end
end
