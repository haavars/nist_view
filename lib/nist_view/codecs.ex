defmodule NistView.Codecs do
  @moduledoc """
  Image codecs implemented in Rust (`native/nist_codecs`). Every function
  runs on a dirty CPU scheduler.

  Decoders return `{:ok, %{width, height, channels, bit_depth, ppi,
  colorspace, pixels}}`, where `pixels` is 8-bit, row-major, `channels`
  bytes per pixel, and `colorspace` is what the decoder knows: `:gray`,
  `:srgb`, `:sycc` (not yet converted) or `:unspecified`. `ppi` is nil
  when the data does not say.
  """

  use Rustler, otp_app: :nist_view, crate: "nist_codecs"

  @type decoded :: %{
          width: pos_integer(),
          height: pos_integer(),
          channels: pos_integer(),
          bit_depth: pos_integer(),
          ppi: pos_integer() | nil,
          colorspace: :gray | :srgb | :sycc | :unspecified,
          pixels: binary()
        }

  @doc "Decodes a WSQ image with the vendored NBIS decoder."
  @spec decode_wsq(binary()) :: {:ok, decoded()} | {:error, atom()}
  def decode_wsq(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes a lossless JPEG (SOF3) image with the vendored NBIS decoder."
  @spec decode_jpegl(binary()) :: {:ok, decoded()} | {:error, atom()}
  def decode_jpegl(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Decodes a JPEG 2000 file or codestream with OpenJPEG, scaled to 8 bits."
  @spec decode_jp2(binary()) :: {:ok, decoded()} | {:error, atom()}
  def decode_jp2(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Converts interleaved full-range YCbCr pixels to RGB."
  @spec ycbcr_to_rgb(binary()) :: {:ok, binary()} | {:error, atom()}
  def ycbcr_to_rgb(_pixels), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Encodes 8-bit pixels (1, 3 or 4 channels) as PNG."
  @spec encode_png(binary(), pos_integer(), pos_integer(), 1 | 3 | 4) ::
          {:ok, binary()} | {:error, atom()}
  def encode_png(_pixels, _width, _height, _channels), do: :erlang.nif_error(:nif_not_loaded)
end
