defmodule NistView.Parser do
  @moduledoc """
  Parses ANSI/NIST-ITL traditional (tagged/binary) transactions.

  Type-1 comes first, and its CNT field (`1.003`) lists every other
  record's type and IDC in order. That list decides how each record is
  read: legacy binary records (Type-3 to Type-8) carry no tag, so CNT is
  the only way to know one comes next. Without a usable CNT, every record
  is read as tagged, which works for files that have no binary records.

  Records are sliced by their declared length, never by scanning for
  separators, because image data may contain separator bytes. Field
  values and image data are sub-binaries of the input; nothing is copied.

  Parsing is total: a malformed file returns everything parsed before the
  problem, with the problem's offset.

  Derived from abis_next's `AbisNext.Nist.Record` and `AbisNext.Nist.File`,
  which were verified against real Prüm and BioCTS files.
  """

  alias NistView.{Compression, Field, ImageFormat, ImageRef, NistFile, Record}

  @fs 0x1C
  @gs <<0x1D>>

  @binary_types [3, 4, 5, 6, 7, 8]

  # Binary image records whose header matches Type-4's 18 bytes.
  @image_binary_types [3, 4, 5, 6]

  # Low-resolution Type-3 and Type-5 images are nominally 250 ppi, the
  # high-resolution Type-4 and Type-6 ones 500 ppi.
  @nominal_ppi %{3 => 250, 4 => 500, 5 => 250, 6 => 500}

  @type error :: {non_neg_integer(), term()}

  @doc """
  Parses a transaction.

  Returns `{:ok, file}`, or `{:error, {offset, reason}, file}` where
  `file` holds the records parsed before the error.
  """
  @spec parse(binary()) :: {:ok, NistFile.t()} | {:error, error(), NistFile.t()}
  def parse(data) when is_binary(data) do
    file = %NistFile{size: byte_size(data)}

    case tagged_record(data, 0) do
      {:ok, %Record{type: 1} = type1, warnings} ->
        {schedule, cnt_warnings} = schedule(type1)
        ctx = %{data: data, resolution: resolution(type1)}
        file = %{file | records: [type1], warnings: warnings ++ cnt_warnings}
        records(ctx, type1.length, schedule, file)

      {:ok, %Record{type: type}, _warnings} ->
        {:error, {0, {:first_record_not_type_1, type}}, file}

      {:error, reason} ->
        {:error, {0, reason}, file}
    end
  end

  # -- Record loop -----------------------------------------------------------

  defp records(ctx, offset, schedule, file) when offset >= byte_size(ctx.data) do
    case schedule do
      [_ | _] -> finish({:error, {offset, {:missing_records, length(schedule)}}}, file)
      _ -> finish(:ok, file)
    end
  end

  defp records(ctx, offset, [], file) do
    file = warn(file, offset, {:trailing_bytes, byte_size(ctx.data) - offset})
    finish(:ok, file)
  end

  defp records(ctx, offset, [{type, idc} | schedule], file) when type in @binary_types do
    case binary_record(ctx, offset, type) do
      {:ok, record, warnings} ->
        file = Enum.reduce(warnings, file, fn {pos, reason}, acc -> warn(acc, pos, reason) end)

        file =
          if record.idc == idc,
            do: file,
            else: warn(file, offset, {:idc_mismatch, idc, record.idc})

        records(ctx, offset + record.length, schedule, add(file, record))

      {:error, reason} ->
        finish({:error, {offset, reason}}, file)
    end
  end

  defp records(ctx, offset, schedule, file) do
    case tagged_record(ctx.data, offset) do
      {:ok, record, warnings} ->
        file = Enum.reduce(warnings, file, fn {pos, reason}, acc -> warn(acc, pos, reason) end)
        file = check_schedule(file, record, schedule)
        next = if is_list(schedule), do: tl(schedule), else: nil
        records(ctx, offset + record.length, next, add(file, record))

      {:error, reason} ->
        finish({:error, {offset, reason}}, file)
    end
  end

  defp check_schedule(file, _record, nil), do: file

  defp check_schedule(file, record, [{type, idc} | _]) do
    cond do
      record.type != type -> warn(file, record.offset, {:type_mismatch, type, record.type})
      record.idc != idc -> warn(file, record.offset, {:idc_mismatch, idc, record.idc})
      true -> file
    end
  end

  defp add(file, record), do: %{file | records: [record | file.records]}

  defp warn(file, offset, reason), do: %{file | warnings: [{offset, reason} | file.warnings]}

  defp finish(result, file) do
    file = %{file | records: Enum.reverse(file.records), warnings: Enum.sort(file.warnings)}

    case result do
      :ok -> {:ok, file}
      {:error, error} -> {:error, error, file}
    end
  end

  # -- Type-1 ----------------------------------------------------------------

  # CNT: the first subfield is "1<US>count", then one "type<US>idc" per
  # record. Returns nil (parse everything as tagged) when CNT is unusable.
  defp schedule(type1) do
    with %Field{subfields: [["1", count] | entries]} <- Record.field(type1, 3),
         {count, ""} <- Integer.parse(count),
         {:ok, schedule} <- cnt_entries(entries) do
      warnings =
        if count == length(schedule),
          do: [],
          else: [{type1.offset, {:cnt_count_mismatch, count, length(schedule)}}]

      {schedule, warnings}
    else
      _ -> {nil, [{type1.offset, :unusable_cnt}]}
    end
  end

  defp cnt_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      [type, idc], {:ok, acc} ->
        with {type, ""} <- Integer.parse(type),
             {idc, ""} <- Integer.parse(idc) do
          {:cont, {:ok, [{type, idc} | acc]}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # NSR (1.011) and NTR (1.012) in pixels per millimetre, as ppi.
  defp resolution(type1) do
    %{nsr: ppmm_to_ppi(Record.value(type1, 11)), ntr: ppmm_to_ppi(Record.value(type1, 12))}
  end

  defp ppmm_to_ppi(nil), do: nil

  defp ppmm_to_ppi(value) do
    case Float.parse(String.trim(value)) do
      {ppmm, ""} when ppmm > 0 -> round(ppmm * 25.4)
      _ -> nil
    end
  end

  # -- Tagged records --------------------------------------------------------

  defp tagged_record(data, offset) do
    available = byte_size(data) - offset
    rest = binary_part(data, offset, available)

    with {:ok, type, len} <- tagged_header(rest),
         :ok <- check_length(len, available) do
      bytes = binary_part(rest, 0, len)
      {fields, warnings} = tagged_fields(bytes, offset)

      record = %Record{
        type: type,
        idc: if(type == 1, do: nil, else: integer(fields, 2)),
        encoding: :tagged,
        offset: offset,
        length: len,
        fields: fields
      }

      {:ok, %{record | image: tagged_image(record)}, warnings}
    end
  end

  # "T.001:LEN" followed by GS (or FS in a record with only a length).
  defp tagged_header(rest) do
    prefix = binary_part(rest, 0, min(byte_size(rest), 32))

    case Regex.run(~r/\A(\d{1,2})\.0*1:(\d+)[\x1D\x1C]/, prefix) do
      [_, type, len] -> {:ok, String.to_integer(type), String.to_integer(len)}
      nil -> {:error, :bad_record_header}
    end
  end

  defp check_length(len, available) do
    cond do
      len < 8 -> {:error, {:bad_length, len}}
      len > available -> {:error, {:truncated, len, available}}
      true -> :ok
    end
  end

  # Walks `T.NNN:value` fields separated by GS. Field 999 is always last
  # and runs to the record's final FS, whatever bytes it contains. A
  # malformed field ends the walk with a warning; the record's length
  # still frames the next record correctly.
  defp tagged_fields(bytes, offset) do
    body_size =
      if :binary.last(bytes) == @fs, do: byte_size(bytes) - 1, else: byte_size(bytes)

    warnings = if body_size == byte_size(bytes), do: [{offset, :missing_fs}], else: []
    body = binary_part(bytes, 0, body_size)

    case walk_fields(body, 0, []) do
      {:ok, fields} -> {fields, warnings}
      {:error, pos, fields} -> {fields, [{offset + pos, :malformed_field} | warnings]}
    end
  end

  defp walk_fields(body, pos, acc) when pos >= byte_size(body), do: {:ok, Enum.reverse(acc)}

  defp walk_fields(body, pos, acc) do
    size = byte_size(body)

    with {colon, 1} <- :binary.match(body, ":", scope: {pos, min(size - pos, 16)}),
         {:ok, number} <- field_number(binary_part(body, pos, colon - pos)) do
      start = colon + 1

      if number == 999 do
        {:ok, Enum.reverse([Field.binary(999, binary_part(body, start, size - start)) | acc])}
      else
        {stop, next} =
          case :binary.match(body, @gs, scope: {start, size - start}) do
            {gs, 1} -> {gs, gs + 1}
            :nomatch -> {size, size}
          end

        field = Field.text(number, binary_part(body, start, stop - start))
        walk_fields(body, next, [field | acc])
      end
    else
      _ -> {:error, pos, Enum.reverse(acc)}
    end
  end

  defp field_number(tag) do
    with [_type, number] <- :binary.split(tag, "."),
         {number, ""} <- Integer.parse(number) do
      {:ok, number}
    else
      _ -> :error
    end
  end

  defp integer(fields, number) do
    with %Field{value: value} <- Enum.find(fields, &(&1.number == number)),
         {int, ""} <- Integer.parse(String.trim(value)) do
      int
    else
      _ -> nil
    end
  end

  # Any tagged record with image data (999) and a compression label (011):
  # Types 10, 13–17, 19, 20 and similar.
  defp tagged_image(%Record{} = record) do
    with %Field{value: data} <- Record.field(record, 999),
         label when is_binary(label) <- Record.value(record, 11) do
      compression = Compression.from_label(label)

      %ImageRef{
        compression: compression,
        format: format(compression, data),
        label: String.trim(label),
        data: data,
        width: integer(record.fields, 6),
        height: integer(record.fields, 7),
        ppi: tagged_ppi(record),
        bit_depth: if(record.type == 10, do: nil, else: integer(record.fields, 12)),
        colorspace: colorspace(record)
      }
    else
      _ -> nil
    end
  end

  # SLC (008): 1 = pixels per inch, 2 = pixels per centimetre, 0 = no scale.
  defp tagged_ppi(record) do
    case {Record.value(record, 8), integer(record.fields, 9)} do
      {"1", ppi} when is_integer(ppi) -> ppi
      {"2", ppcm} when is_integer(ppcm) -> round(ppcm * 2.54)
      _ -> nil
    end
  end

  # Uncompressed pixels could start with a signature by chance, so only a
  # compressed label is overridden by what the bytes say.
  defp format(:raw, _data), do: :raw

  defp format(compression, data) do
    case ImageFormat.detect(data) do
      nil -> compression
      :jp2 when compression == :jp2l -> :jp2l
      detected -> detected
    end
  end

  defp colorspace(%Record{type: 10} = record), do: Record.value(record, 12)

  defp colorspace(%Record{type: type} = record) when type in [16, 17],
    do: Record.value(record, 13)

  defp colorspace(_record), do: nil

  # -- Binary records --------------------------------------------------------

  defp binary_record(ctx, offset, type) do
    available = byte_size(ctx.data) - offset

    with <<len::32, _::binary>> <- binary_part(ctx.data, offset, min(available, 4)),
         :ok <- check_binary_length(type, len, available) do
      bytes = binary_part(ctx.data, offset, len)

      {fields, image, warnings} =
        if len >= binary_header_size(type) do
          {fields, image} = binary_fields(type, bytes, ctx.resolution)
          {fields, image, []}
        else
          <<_::32, idc, rest::binary>> = bytes
          {[num(1, len), num(2, idc), Field.binary(3, rest)], nil, [{offset, :short_record}]}
        end

      record = %Record{
        type: type,
        idc: integer(fields, 2),
        encoding: :binary,
        offset: offset,
        length: len,
        fields: fields,
        image: image
      }

      {:ok, record, warnings}
    else
      bytes when is_binary(bytes) -> {:error, {:truncated, 4, available}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every binary record has at least LEN and IDC. One shorter than its
  # type's header is still framed correctly, so it is kept with a warning.
  defp check_binary_length(_type, len, available) do
    cond do
      len < 5 -> {:error, {:bad_length, len}}
      len > available -> {:error, {:truncated, len, available}}
      true -> :ok
    end
  end

  defp binary_header_size(type) when type in @image_binary_types, do: 18
  defp binary_header_size(7), do: 5
  defp binary_header_size(8), do: 12

  # Type-3 to Type-6: LEN, IDC, IMP, FGP (6 bytes, 255 = unused), ISR,
  # HLL, VLL, GCA, then the image.
  defp binary_fields(type, bytes, resolution) when type in @image_binary_types do
    <<len::32, idc, imp, fgp::binary-6, isr, hll::16, vll::16, gca, data::binary>> = bytes

    positions = for <<p <- fgp>>, p != 255, do: Integer.to_string(p)

    fields = [
      num(1, len),
      num(2, idc),
      num(3, imp),
      Field.text(4, Enum.join(positions, <<0x1F>>)),
      num(5, isr),
      num(6, hll),
      num(7, vll),
      num(8, gca),
      Field.binary(9, data)
    ]

    {compression, label, depth} =
      if type in [3, 4],
        do: {Compression.from_gca(gca), Integer.to_string(gca), 8},
        else: {:unknown, "#{gca} (bi-level)", 1}

    image = %ImageRef{
      compression: compression,
      format: format(compression, data),
      label: label,
      data: data,
      width: hll,
      height: vll,
      ppi: if(isr == 1, do: resolution.nsr, else: @nominal_ppi[type]),
      bit_depth: depth
    }

    {fields, image}
  end

  # Type-7: user-defined after LEN and IDC.
  defp binary_fields(7, <<len::32, idc, data::binary>>, _resolution) do
    {[num(1, len), num(2, idc), Field.binary(3, data)], nil}
  end

  # Type-8 signature: LEN, IDC, SIG, SRT, ISR, HLL, VLL, then the data.
  defp binary_fields(8, bytes, _resolution) do
    <<len::32, idc, sig, srt, isr, hll::16, vll::16, data::binary>> = bytes

    fields = [
      num(1, len),
      num(2, idc),
      num(3, sig),
      num(4, srt),
      num(5, isr),
      num(6, hll),
      num(7, vll),
      Field.binary(8, data)
    ]

    {fields, nil}
  end

  defp num(number, value), do: Field.text(number, Integer.to_string(value))
end
