defmodule Mix.Tasks.Nist.Samples do
  @shortdoc "Downloads NIST's BioCTS sample transactions into test/samples/biocts/"

  @moduledoc """
  Downloads the sample data that ships with NIST's BioCTS conformance test
  tool for ANSI/NIST-ITL (about 150 MB, public, no registration) and
  extracts its traditional-encoding files (`.an2`, about 110 MB) into
  `test/samples/biocts/`.

      $ mix nist.samples

  The directory is gitignored. `NistView.BioctsSampleTest` runs against it
  and is skipped when it is missing. Run once per machine; running again
  replaces the files.
  """

  use Mix.Task

  @archive_url "https://www.nist.gov/system/files/documents/2016/12/13/biocts_ansi_nist_itl_2.0.6107.19926_sample_data_1.zip"
  @prefix "AN2011_SampleData/Traditional Encoding/"
  @target_dir "test/samples/biocts"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    Mix.shell().info("Downloading #{@archive_url} (~150 MB)...")
    %Req.Response{status: 200, body: zip} = Req.get!(@archive_url, decode_body: false)

    {:ok, entries} = :zip.list_dir(zip)

    wanted =
      for {:zip_file, name, _info, _comment, _offset, _size} <- entries,
          name = List.to_string(name),
          String.starts_with?(name, @prefix) and String.ends_with?(name, ".an2"),
          do: String.to_charlist(name)

    {:ok, files} = :zip.extract(zip, [:memory, file_list: wanted])

    File.rm_rf!(@target_dir)
    File.mkdir_p!(@target_dir)

    for {name, bytes} <- files do
      File.write!(Path.join(@target_dir, Path.basename(List.to_string(name))), bytes)
    end

    Mix.shell().info("Extracted #{length(files)} files into #{@target_dir}/")
  end
end
