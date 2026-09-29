defmodule NistView.Viewer do
  @moduledoc """
  What the viewer shows, derived from a parsed file. Kept separate from
  the LiveView so it can be tested on its own.
  """

  alias NistView.{Field, FieldNames, ImageRef, Minutiae, NistFile, Positions, Record}

  @finger_image_types [4, 14]

  @doc "Header facts from Type-1: version, transaction type, control number, date."
  @spec summary(NistFile.t()) :: %{atom() => String.t() | nil}
  def summary(%NistFile{records: [%Record{type: 1} = type1 | _]}) do
    %{
      version: Record.value(type1, 2),
      tot: Record.value(type1, 4),
      date: format_date(Record.value(type1, 5)),
      tcn: Record.value(type1, 9),
      domain: domain(Record.field(type1, 13))
    }
  end

  def summary(%NistFile{}), do: %{version: nil, tot: nil, date: nil, tcn: nil, domain: nil}

  defp format_date(<<y::binary-4, m::binary-2, d::binary-2>>), do: "#{y}-#{m}-#{d}"
  defp format_date(other), do: other

  defp domain(%Field{subfields: [[name | rest] | _]}), do: Enum.join([name | rest], " ")
  defp domain(_), do: nil

  @doc "A short title for a record, such as `Right index` or `Face`."
  @spec title(Record.t()) :: String.t()
  def title(%Record{type: type} = record) when type in [4, 13, 14, 15] do
    case position(record) do
      nil -> FieldNames.record(type)
      code -> Positions.name(code) || "Position #{code}"
    end
  end

  def title(%Record{type: 9} = record) do
    case Minutiae.decode(record) do
      [] -> "Minutiae"
      sets -> "Minutiae · " <> Enum.map_join(sets, ", ", &format_name/1)
    end
  end

  def title(%Record{type: 10} = record) do
    case Record.value(record, 3) do
      nil -> FieldNames.record(10)
      imt -> String.capitalize(imt)
    end
  end

  def title(%Record{type: type}), do: FieldNames.record(type) || "Type-#{type}"

  defp format_name(%Minutiae{format: :m1}), do: "INCITS 378"
  defp format_name(%Minutiae{format: :standard}), do: "standard"
  defp format_name(%Minutiae{format: :fbi}), do: "FBI"
  defp format_name(%Minutiae{format: :efs}), do: "EFS"

  @doc "One line describing a record's image, or nil."
  @spec image_summary(Record.t()) :: String.t() | nil
  def image_summary(%Record{image: %ImageRef{} = image}) do
    [
      codec_name(image),
      image.width && image.height && "#{image.width}×#{image.height}",
      image.ppi && "#{image.ppi} ppi"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def image_summary(%Record{}), do: nil

  @doc "The codec name shown for an image, noting when its label is wrong."
  @spec codec_name(ImageRef.t()) :: String.t()
  def codec_name(%ImageRef{} = image) do
    name = codec(image.format)

    if image.format == image.compression or {image.compression, image.format} == {:jp2l, :jp2},
      do: name,
      else: "#{name} (labelled #{image.label})"
  end

  defp codec(:raw), do: "Uncompressed"
  defp codec(:wsq), do: "WSQ"
  defp codec(:jpegb), do: "JPEG"
  defp codec(:jpegl), do: "Lossless JPEG"
  defp codec(:jp2), do: "JPEG 2000"
  defp codec(:jp2l), do: "JPEG 2000 lossless"
  defp codec(:png), do: "PNG"
  defp codec(:unknown), do: "Unknown"

  @doc "The first friction ridge position (FGP) of a Type-4/13/14/15 record."
  @spec position(Record.t()) :: integer() | nil
  def position(%Record{type: type} = record) when type in [4, 13, 14, 15] do
    number = if type == 4, do: 4, else: 13

    with %Field{subfields: [[first | _] | _]} <- Record.field(record, number),
         {code, ""} <- Integer.parse(String.trim(first)) do
      code
    else
      _ -> nil
    end
  end

  def position(%Record{}), do: nil

  @doc """
  The tenprint card: finger positions 1–15 mapped to the index of the
  first Type-4 or Type-14 record with that position.
  """
  @spec tenprint(NistFile.t()) :: %{pos_integer() => non_neg_integer()}
  def tenprint(%NistFile{records: records}) do
    records
    |> Enum.with_index()
    |> Enum.filter(fn {record, _} -> record.type in @finger_image_types and record.image end)
    |> Enum.reduce(%{}, fn {record, index}, acc ->
      case position(record) do
        code when code in 1..15 -> Map.put_new(acc, code, index)
        _ -> acc
      end
    end)
  end

  @doc """
  Minutiae to overlay on the image of record `index`: every block of each
  Type-9 record with the same IDC, converted to the image's pixels. Empty
  when the image has no resolution to convert with.
  """
  @spec minutiae_for(NistFile.t(), non_neg_integer()) :: [Minutiae.t()]
  def minutiae_for(%NistFile{records: records}, index) do
    with %Record{idc: idc, image: %ImageRef{ppi: ppi, height: height}} when is_integer(idc) <-
           Enum.at(records, index),
         true <- is_integer(ppi) and ppi > 0 and is_integer(height) do
      for %Record{type: 9, idc: ^idc} = type9 <- records,
          set <- Minutiae.decode(type9),
          do: Minutiae.to_pixels(set, ppi, height)
    else
      _ -> []
    end
  end

  @doc """
  Hex dump lines for `bytes`: `{offset, hex, ascii}`, 16 bytes a line,
  with offsets starting at `base`.
  """
  @spec hex_lines(binary(), non_neg_integer()) :: [{non_neg_integer(), String.t(), String.t()}]
  def hex_lines(bytes, base \\ 0) do
    for {line, i} <- Enum.with_index(chunks(bytes)) do
      hex =
        line
        |> :binary.bin_to_list()
        |> Enum.map(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
        |> Enum.chunk_every(8)
        |> Enum.map_join("  ", &Enum.join(&1, " "))

      ascii = for <<b <- line>>, into: "", do: if(b in 0x20..0x7E, do: <<b>>, else: ".")
      {base + i * 16, hex, ascii}
    end
  end

  defp chunks(<<line::binary-16, rest::binary>>), do: [line | chunks(rest)]
  defp chunks(<<>>), do: []
  defp chunks(rest), do: [rest]

  @doc "A plain-language description of a parser error or warning, or an image error."
  @spec describe(term()) :: String.t()
  def describe({:truncated, declared, available}),
    do: "the record declares #{declared} bytes but only #{available} remain"

  def describe({:missing_records, n}),
    do: "Type-1 lists #{n} more record(s) than the file contains"

  def describe(:bad_record_header), do: "no record header found (not an ANSI/NIST-ITL file?)"
  def describe({:bad_length, len}), do: "invalid record length #{len}"

  def describe({:first_record_not_type_1, type}),
    do: "the file starts with Type-#{type}, not Type-1"

  def describe(:unusable_cnt), do: "Type-1 CNT (1.003) is unreadable; records were read by tag"

  def describe({:cnt_count_mismatch, count, listed}),
    do: "CNT says #{count} records but lists #{listed}"

  def describe({:type_mismatch, expected, got}),
    do: "CNT expected Type-#{expected} here, found Type-#{got}"

  def describe({:idc_mismatch, expected, got}),
    do: "CNT expected IDC #{expected}, the record says #{inspect(got)}"

  def describe({:trailing_bytes, n}), do: "#{n} byte(s) after the last record"
  def describe(:missing_fs), do: "record does not end with a file separator"
  def describe(:malformed_field), do: "malformed field; the rest of this record was skipped"
  def describe(:short_record), do: "binary record is shorter than its header"
  def describe({:unsupported_compression, format}), do: "#{format} images are not supported"

  def describe({:unsupported_raw_layout, size, w, h, depth}),
    do: "#{size} bytes do not fit #{w}×#{h} at #{inspect(depth)} bits per pixel"

  def describe(:too_large), do: "image is larger than 100 megapixels"
  def describe(:unsupported_colorspace), do: "unsupported colour space"
  def describe(:not_lossless_jpeg), do: "data is not lossless JPEG"

  def describe(reason)
      when reason in [:invalid_wsq, :invalid_jpegl, :invalid_jp2, :invalid_dimensions],
      do: "the image data is invalid or corrupt"

  def describe(reason), do: inspect(reason)
end
