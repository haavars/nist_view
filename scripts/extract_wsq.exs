# Writes every distinct WSQ image in test/fixtures and test/samples to a
# directory, one file per image named by SHA-1. Used to compare WSQ decoders
# (see docs/wsq-port.md). The output contains BioCTS prints: keep it out of git.
#
#     mix run scripts/extract_wsq.exs OUT_DIR
[out] = System.argv()
File.mkdir_p!(out)

paths = Path.wildcard("test/fixtures/*.an2") ++ Path.wildcard("test/samples/**/*.an2")

images =
  for path <- paths,
      {_, file} =
        (case NistView.Parser.parse(File.read!(path)) do
           {:ok, file} -> {:ok, file}
           {:error, _, file} -> {:error, file}
         end),
      %{image: %{format: :wsq, data: data}} <- file.records,
      do: data

images = Enum.uniq([File.read!("test/fixtures/synthetic.wsq") | images])

for data <- images do
  File.write!(
    Path.join(out, Base.encode16(:crypto.hash(:sha, data), case: :lower) <> ".wsq"),
    data
  )
end

IO.puts("#{length(images)} distinct WSQ images written to #{out}")
