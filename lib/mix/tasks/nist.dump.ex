defmodule Mix.Tasks.Nist.Dump do
  @shortdoc "Prints the record tree of an ANSI/NIST-ITL file"

  @moduledoc """
  Prints every record and field of an ANSI/NIST-ITL transaction.

      $ mix nist.dump path/to/file.an2 [--decode] [--png DIR] [--full]

  Options:

    * `--decode` - decode every image and report its size (WSQ and
      uncompressed images are converted to PNG in memory)
    * `--png DIR` - also write each displayable image to `DIR`. This writes
      biometric data to disk, so only use it on test data
    * `--full` - print long field values in full instead of truncating them

  Exits with status 1 if the file could not be parsed completely; the
  records parsed before the error are still printed.
  """

  use Mix.Task

  alias NistView.{Field, FieldNames, ImageRef, Imaging, Minutiae, NistFile, Parser, Record}

  @max_subfields 8
  @max_chars 100

  @impl Mix.Task
  def run(args) do
    {opts, paths} =
      OptionParser.parse!(args, strict: [decode: :boolean, png: :string, full: :boolean])

    path =
      case paths do
        [path] -> path
        _ -> Mix.raise("Usage: mix nist.dump FILE [--decode] [--png DIR] [--full]")
      end

    Mix.Task.run("compile")

    data = File.read!(path)

    {file, error} =
      case Parser.parse(data) do
        {:ok, file} -> {file, nil}
        {:error, error, file} -> {file, error}
      end

    opts = Map.new(opts)
    if opts[:png], do: File.mkdir_p!(opts.png)

    print_summary(path, file)

    file.records
    |> Enum.with_index()
    |> Enum.each(fn {record, index} -> print_record(record, index, path, opts) end)

    print_warnings(file)

    if error do
      {offset, reason} = error
      Mix.shell().error("\nParse error at byte #{offset}: #{inspect(reason)}")
      exit({:shutdown, 1})
    end
  end

  defp print_summary(path, %NistFile{} = file) do
    IO.puts("#{Path.basename(path)}  #{file.size} bytes, #{length(file.records)} records\n")
  end

  defp print_record(%Record{} = record, index, path, opts) do
    idc = if record.idc, do: "  IDC #{record.idc}", else: ""
    kind = if record.encoding == :binary, do: ", binary", else: ""

    IO.puts(
      "Type-#{record.type}  #{FieldNames.record(record.type) || "Unknown record type"}#{idc}" <>
        "  (@#{record.offset}, #{record.length} bytes#{kind})"
    )

    Enum.each(record.fields, &print_field(record.type, &1, opts))

    if record.image, do: print_image(record, index, path, opts)
    Enum.each(Minutiae.decode(record), &print_minutiae/1)

    IO.puts("")
  end

  defp print_field(type, %Field{} = field, opts) do
    tag = "#{type}.#{pad(field.number)}"
    name = FieldNames.field(type, field.number) || ""
    label = String.pad_trailing("  #{tag} #{name}", 20)

    case lines(field, opts) do
      [first | rest] ->
        IO.puts(label <> first)
        Enum.each(rest, &IO.puts(String.duplicate(" ", 20) <> &1))

      [] ->
        IO.puts(label)
    end
  end

  defp lines(%Field{} = field, opts) do
    if Field.binary?(field) do
      ["<#{byte_size(field.value)} bytes>"]
    else
      subfields = Enum.map(field.subfields, &Enum.map_join(&1, " | ", fn item -> text(item) end))

      if opts[:full] || length(subfields) <= @max_subfields do
        Enum.map(subfields, &truncate(&1, opts))
      else
        shown = Enum.take(subfields, @max_subfields)
        Enum.map(shown, &truncate(&1, opts)) ++ ["… #{length(subfields) - @max_subfields} more"]
      end
    end
  end

  defp text(item) do
    if String.printable?(item), do: item, else: "<#{byte_size(item)} bytes, not text>"
  end

  defp truncate(line, opts) do
    if opts[:full] || String.length(line) <= @max_chars,
      do: line,
      else: String.slice(line, 0, @max_chars) <> "…"
  end

  defp print_image(%Record{image: %ImageRef{} = image} = record, index, path, opts) do
    size = if image.width, do: "  #{image.width}×#{image.height}", else: ""
    ppi = if image.ppi, do: "  #{image.ppi} ppi", else: ""
    depth = if image.bit_depth, do: "  #{image.bit_depth}-bit", else: ""
    colour = if image.colorspace, do: "  #{image.colorspace}", else: ""

    actual = if image.format == image.compression, do: "", else: ", data is #{image.format}"

    IO.puts(
      "  image: #{image.compression} (#{image.label}#{actual})#{size}#{ppi}#{depth}#{colour}"
    )

    if opts[:decode] || opts[:png] do
      case Imaging.displayable(image) do
        {:ok, mime, bytes} ->
          IO.puts("         displayable as #{mime}, #{byte_size(bytes)} bytes")
          if opts[:png], do: write_image(opts.png, path, index, record, mime, bytes)

        {:error, reason} ->
          IO.puts("         not displayable: #{inspect(reason)}")
      end
    end
  end

  defp print_minutiae(%Minutiae{} = set) do
    IO.puts(
      "  minutiae: #{set.format}, #{length(set.minutiae)} minutiae, " <>
        "#{length(set.cores)} cores, #{length(set.deltas)} deltas"
    )
  end

  defp write_image(dir, path, index, record, mime, bytes) do
    ext = if mime == "image/jpeg", do: "jpg", else: "png"

    name =
      "#{Path.rootname(Path.basename(path))}_#{index}_type#{record.type}_idc#{record.idc}.#{ext}"

    File.write!(Path.join(dir, name), bytes)
    IO.puts("         wrote #{Path.join(dir, name)}")
  end

  defp print_warnings(%NistFile{warnings: []}), do: :ok

  defp print_warnings(%NistFile{warnings: warnings}) do
    IO.puts("Warnings:")
    Enum.each(warnings, fn {offset, reason} -> IO.puts("  @#{offset}: #{inspect(reason)}") end)
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(3, "0")
end
