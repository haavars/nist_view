# Checks a built desktop release on the machine that built it: its Erlang
# runtime, the codecs NIF and the nist_decode helper. Run by CI after the
# bundle is built (docs/ci.md, step 3):
#
#     src-tauri/target/rel/bin/nist_view eval 'Code.eval_file("scripts/release_smoke.exs")'

alias NistView.{Codecs, Decoder}

fixtures = Path.expand("../test/fixtures", __DIR__)

for {format, file} <- [
      wsq: "synthetic.wsq",
      jpegl: "synthetic_grey.jpl",
      jp2: "synthetic_grey.jp2"
    ] do
  {:ok, image} = Decoder.decode(format, File.read!(Path.join(fixtures, file)))

  {:ok, <<0x89, "PNG", _::binary>>} =
    Codecs.encode_png(image.pixels, image.width, image.height, image.channels)

  IO.puts("#{file}: #{image.width} x #{image.height}, #{image.channels} channel(s)")
end

IO.puts("Release smoke test passed on #{:erlang.system_info(:system_architecture)}")
