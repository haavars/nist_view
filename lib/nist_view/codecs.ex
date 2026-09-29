defmodule NistView.Codecs do
  @moduledoc """
  Image codecs implemented in Rust (`native/nist_codecs`). Every function
  runs on a dirty CPU scheduler.

  Decoders return `{:ok, %{width, height, channels, bit_depth, ppi, pixels}}`,
  where `pixels` is 8-bit, row-major, `channels` bytes per pixel.
  """

  use Rustler, otp_app: :nist_view, crate: "nist_codecs"

  @type decoded :: %{
          width: pos_integer(),
          height: pos_integer(),
          channels: pos_integer(),
          bit_depth: pos_integer(),
          ppi: integer(),
          pixels: binary()
        }

  @doc "Decodes a WSQ image with the vendored NBIS decoder."
  @spec decode_wsq(binary()) :: {:ok, decoded()} | {:error, atom()}
  def decode_wsq(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Encodes 8-bit pixels (1, 3 or 4 channels) as PNG."
  @spec encode_png(binary(), pos_integer(), pos_integer(), 1 | 3 | 4) ::
          {:ok, binary()} | {:error, atom()}
  def encode_png(_pixels, _width, _height, _channels), do: :erlang.nif_error(:nif_not_loaded)
end
