defmodule NistView.Imaging do
  @moduledoc """
  Turns an embedded image into bytes a browser can show.

  Decoding follows the image's detected `format`, not its label (see
  `NistView.ImageFormat`). PNG and baseline JPEG go through unchanged: the
  webview decodes them. Everything else is decoded and re-encoded as PNG
  in memory. Nothing is written to disk.
  """

  alias NistView.{Codecs, Decoder, ImageRef}

  @type displayable :: {:ok, mime :: String.t(), bytes :: binary()} | {:error, term()}

  # Record colour spaces (10.012, 17.013) that mean YCbCr samples.
  @ycc_labels ["YCC", "SYCC"]

  @doc "Returns the image as PNG or JPEG bytes for display."
  @spec displayable(ImageRef.t()) :: displayable()
  def displayable(%ImageRef{format: :png, data: data}), do: {:ok, "image/png", data}
  def displayable(%ImageRef{format: :jpegb, data: data}), do: {:ok, "image/jpeg", data}

  def displayable(%ImageRef{} = image) do
    with {:ok, decoded} <- decode(image),
         {:ok, png} <-
           Codecs.encode_png(decoded.pixels, decoded.width, decoded.height, decoded.channels) do
      {:ok, "image/png", png}
    end
  end

  @doc """
  Whether `preview/2` can make a smaller image faster than the full one:
  JPEG 2000 at least twice `target` in both directions, or of unknown size.
  """
  @spec previewable?(ImageRef.t(), {pos_integer(), pos_integer()}) :: boolean()
  def previewable?(%ImageRef{format: format, width: w, height: h}, {tw, th})
      when format in [:jp2, :jp2l] do
    not (is_integer(w) and is_integer(h)) or (w >= 2 * tw and h >= 2 * th)
  end

  def previewable?(%ImageRef{}, _target), do: false

  @doc """
  Like `displayable/1`, but decodes JPEG 2000 at a reduced resolution of at
  least `target` (see `NistView.Decoder.decode_preview/3`), which is several
  times faster for a large image. Returns `{:preview, mime, bytes, {width,
  height}}` with the full size when the image was reduced, and what
  `displayable/1` returns otherwise.
  """
  @spec preview(ImageRef.t(), {pos_integer(), pos_integer()}) ::
          {:preview, String.t(), binary(), {pos_integer(), pos_integer()}} | displayable()
  def preview(%ImageRef{format: format, data: data} = image, target)
      when format in [:jp2, :jp2l] do
    with {:ok, decoded} <- Decoder.decode_preview(data, target),
         {:ok, decoded} <- to_rgb(decoded, image),
         {:ok, png} <-
           Codecs.encode_png(decoded.pixels, decoded.width, decoded.height, decoded.channels) do
      if decoded.width < decoded.full_width,
        do: {:preview, "image/png", png, {decoded.full_width, decoded.full_height}},
        else: {:ok, "image/png", png}
    end
  end

  def preview(%ImageRef{} = image, _target), do: displayable(image)

  @doc """
  Decodes an image to 8-bit greyscale or RGB pixels. Supports WSQ,
  lossless JPEG, JPEG 2000 and uncompressed 8-bit data. YCbCr images are
  converted to RGB.
  """
  @spec decode(ImageRef.t()) :: {:ok, Codecs.decoded()} | {:error, term()}
  def decode(%ImageRef{} = image) do
    with {:ok, decoded} <- decode_format(image) do
      to_rgb(decoded, image)
    end
  end

  defp decode_format(%ImageRef{format: :wsq, data: data}), do: Decoder.decode(:wsq, data)
  defp decode_format(%ImageRef{format: :jpegl, data: data}), do: Decoder.decode(:jpegl, data)

  defp decode_format(%ImageRef{format: format, data: data}) when format in [:jp2, :jp2l],
    do: Decoder.decode(:jp2, data)

  defp decode_format(%ImageRef{format: :raw, width: w, height: h, data: data} = image)
       when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    channels = div(byte_size(data), w * h)

    if channels in [1, 3] and byte_size(data) == w * h * channels and
         image.bit_depth in [nil, 8, 24] do
      {:ok,
       %{
         width: w,
         height: h,
         channels: channels,
         bit_depth: 8,
         ppi: image.ppi,
         colorspace: if(channels == 1, do: :gray, else: :unspecified),
         pixels: data
       }}
    else
      {:error, {:unsupported_raw_layout, byte_size(data), w, h, image.bit_depth}}
    end
  end

  defp decode_format(%ImageRef{format: format}), do: {:error, {:unsupported_compression, format}}

  # Converts YCbCr to RGB when the data says so, or when the decoder cannot
  # tell and the record's colour space field says so.
  defp to_rgb(%{channels: 3, colorspace: colorspace} = decoded, image)
       when colorspace in [:sycc, :unspecified] do
    if colorspace == :sycc or ycc_label?(image.colorspace) do
      with {:ok, rgb} <- Codecs.ycbcr_to_rgb(decoded.pixels) do
        {:ok, %{decoded | pixels: rgb, colorspace: :srgb}}
      end
    else
      {:ok, decoded}
    end
  end

  defp to_rgb(decoded, _image), do: {:ok, decoded}

  defp ycc_label?(nil), do: false
  defp ycc_label?(label), do: String.upcase(String.trim(label)) in @ycc_labels
end
