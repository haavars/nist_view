defmodule NistView.ImageFormat do
  @moduledoc """
  Detects an image's format from its bytes.

  Labels in files are not always right: two BioCTS Type-14 records say
  `JPEGL` but hold baseline JPEG. Decoding follows the bytes when they
  identify the format, and the label otherwise.
  """

  @doc """
  Returns the format the data starts with, or nil if unrecognised. JPEG
  frames other than baseline, extended, progressive and lossless give
  `:unknown`.
  """
  @spec detect(binary()) :: NistView.Compression.t() | nil
  def detect(<<0xFF, 0xA0, _::binary>>), do: :wsq
  def detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: :png
  def detect(<<0x00, 0x00, 0x00, 0x0C, "jP  ", _::binary>>), do: :jp2
  def detect(<<0xFF, 0x4F, 0xFF, 0x51, _::binary>>), do: :jp2
  def detect(<<0xFF, 0xD8, rest::binary>>), do: jpeg_frame(rest)
  def detect(_data), do: nil

  # Walks marker segments to the first frame header (SOFn).
  defp jpeg_frame(<<0xFF, 0xFF, rest::binary>>), do: jpeg_frame(<<0xFF, rest::binary>>)

  defp jpeg_frame(<<0xFF, code, _::binary>>) when code in [0xC0, 0xC1, 0xC2], do: :jpegb
  defp jpeg_frame(<<0xFF, 0xC3, _::binary>>), do: :jpegl

  defp jpeg_frame(<<0xFF, code, _::binary>>)
       when code in 0xC5..0xCF and code not in [0xC8, 0xCC],
       do: :unknown

  defp jpeg_frame(<<0xFF, code, len::16, rest::binary>>)
       when code not in [0xDA, 0xD9] and len >= 2 and byte_size(rest) >= len - 2 do
    <<_::binary-size(len - 2), rest::binary>> = rest
    jpeg_frame(rest)
  end

  defp jpeg_frame(_rest), do: nil
end
