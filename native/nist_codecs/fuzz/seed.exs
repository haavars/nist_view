# Seeds the fuzz corpora with real images: every embedded image in
# test/fixtures and test/samples, by detected format, up to 256 KB each.
#
#     mix run native/nist_codecs/fuzz/seed.exs
#
# The corpora are gitignored: images from test/samples are real prints.
corpus = Path.expand("corpus", __DIR__)
targets = %{wsq: "wsq", jpegl: "jpegl", jp2: "jp2", jp2l: "jp2"}

transactions =
  Path.wildcard("test/fixtures/*.an2") ++ Path.wildcard("test/samples/**/*.an2")

images =
  for path <- transactions,
      {_, file} = (case NistView.Parser.parse(File.read!(path)) do
                     {:ok, file} -> {:ok, file}
                     {:error, _, file} -> {:error, file}
                   end),
      %{image: %{format: format, data: data}} <- file.records,
      Map.has_key?(targets, format),
      byte_size(data) <= 262_144,
      do: {targets[format], data}

loose =
  for {name, target} <- [
        {"synthetic.wsq", "wsq"},
        {"synthetic_grey.jpl", "jpegl"},
        {"synthetic_rgb.jpl", "jpegl"},
        {"synthetic_ycc420.jpl", "jpegl"},
        {"synthetic_grey.jp2", "jp2"},
        {"synthetic_rgb.j2k", "jp2"},
        {"synthetic_grey16.jp2", "jp2"}
      ],
      do: {target, File.read!(Path.join("test/fixtures", name))}

# The generated JPEG 2000 files: small, and between them most coding options.
generated =
  for path <- Path.wildcard("test/fixtures/jp2/*"), do: {"jp2", File.read!(path)}

seeds = Enum.uniq(images ++ loose ++ generated)

for {target, data} <- seeds do
  dir = Path.join(corpus, target)
  File.mkdir_p!(dir)
  File.write!(Path.join(dir, Base.encode16(:crypto.hash(:sha, data), case: :lower)), data)
  # The header readers take any of them.
  File.mkdir_p!(Path.join(corpus, "headers"))
  File.write!(Path.join([corpus, "headers", Base.encode16(:crypto.hash(:sha, data), case: :lower)]), binary_part(data, 0, min(byte_size(data), 4096)))
end

seeds
|> Enum.frequencies_by(&elem(&1, 0))
|> Enum.each(fn {target, n} -> IO.puts("#{target}: #{n} seeds") end)
