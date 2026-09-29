defmodule NistView.Imaging do
  @moduledoc """
  Turns an embedded image into bytes a browser can show.

  PNG and baseline JPEG go through unchanged: the webview decodes them.
  WSQ and uncompressed images are decoded and re-encoded as PNG in
  memory. Nothing is written to disk.
  """

  alias NistView.{Codecs, ImageRef}

  @type displayable :: {:ok, mime :: String.t(), bytes :: binary()} | {:error, term()}

  @doc "Returns the image as PNG or JPEG bytes for display."
  @spec displayable(ImageRef.t()) :: displayable()
  def displayable(%ImageRef{compression: :png, data: data}), do: {:ok, "image/png", data}
  def displayable(%ImageRef{compression: :jpegb, data: data}), do: {:ok, "image/jpeg", data}

  def displayable(%ImageRef{} = image) do
    with {:ok, decoded} <- decode(image),
         {:ok, png} <-
           Codecs.encode_png(decoded.pixels, decoded.width, decoded.height, decoded.channels) do
      {:ok, "image/png", png}
    end
  end

  @doc """
  Decodes an image to 8-bit pixels. Supports WSQ and uncompressed 8-bit
  greyscale or RGB.
  """
  @spec decode(ImageRef.t()) :: {:ok, Codecs.decoded()} | {:error, term()}
  def decode(%ImageRef{compression: :wsq, data: data}), do: Codecs.decode_wsq(data)

  def decode(%ImageRef{compression: :raw, width: w, height: h, data: data} = image)
      when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    channels = div(byte_size(data), w * h)

    if channels in [1, 3] and byte_size(data) == w * h * channels and
         image.bit_depth in [nil, 8, 24] do
      {:ok,
       %{width: w, height: h, channels: channels, bit_depth: 8, ppi: image.ppi, pixels: data}}
    else
      {:error, {:unsupported_raw_layout, byte_size(data), w, h, image.bit_depth}}
    end
  end

  def decode(%ImageRef{compression: compression}),
    do: {:error, {:unsupported_compression, compression}}
end
