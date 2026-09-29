defmodule NistView.CodecsTest do
  use ExUnit.Case, async: true

  alias NistView.{Codecs, ImageRef, Imaging}

  @wsq File.read!("test/fixtures/synthetic.wsq")
  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  # The pattern in synthetic.wsq (see test/fixtures/README.md).
  defp expected_pixel(x, y), do: trunc(128 + 90 * :math.sin(x / 2.5) * :math.cos(y / 3.5))

  describe "decode_wsq/1" do
    test "decodes the synthetic image close to its source pattern" do
      assert {:ok, decoded} = Codecs.decode_wsq(@wsq)
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
      assert {:error, :invalid_wsq} = Codecs.decode_wsq("not wsq")
      assert {:error, :invalid_wsq} = Codecs.decode_wsq(<<>>)
    end

    test "rejects every truncation of a valid image without crashing" do
      for size <- 0..(byte_size(@wsq) - 1)//7 do
        assert {:error, _} = Codecs.decode_wsq(binary_part(@wsq, 0, size))
      end
    end

    test "refuses images above the pixel limit before decoding" do
      # Frame header dimensions patched to 65535 × 65535.
      {pos, 2} = :binary.match(@wsq, <<0xFF, 0xA2>>)
      <<before::binary-size(pos + 6), _::32, rest::binary>> = @wsq

      assert {:error, :too_large} =
               Codecs.decode_wsq(<<before::binary, 0xFFFF::16, 0xFFFF::16, rest::binary>>)
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
      image = %ImageRef{compression: :wsq, label: "WSQ20", data: @wsq}
      assert {:ok, "image/png", <<@png_signature, _::binary>>} = Imaging.displayable(image)
    end

    test "converts uncompressed greyscale to PNG" do
      image = %ImageRef{
        compression: :raw,
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
               Imaging.displayable(%ImageRef{compression: :png, label: "PNG", data: "png"})

      assert {:ok, "image/jpeg", "jpg"} =
               Imaging.displayable(%ImageRef{compression: :jpegb, label: "JPEGB", data: "jpg"})
    end

    test "reports codecs that are not supported yet" do
      assert {:error, {:unsupported_compression, :jp2}} =
               Imaging.displayable(%ImageRef{compression: :jp2, label: "JP2", data: <<>>})
    end

    test "rejects uncompressed data that does not fit its dimensions" do
      image = %ImageRef{
        compression: :raw,
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
