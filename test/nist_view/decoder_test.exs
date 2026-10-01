defmodule NistView.DecoderTest do
  # Changes the decoder executable in application config, so not async.
  use ExUnit.Case, async: false

  alias NistView.Decoder

  @wsq File.read!("test/fixtures/synthetic.wsq")

  defp with_executable(path) do
    Application.put_env(:nist_view, :decoder_executable, Path.expand(path))
    on_exit(fn -> Application.delete_env(:nist_view, :decoder_executable) end)
  end

  test "decodes in a helper process that exits afterwards" do
    assert {:ok, %{width: 128, height: 96}} = Decoder.decode(:wsq, @wsq)
    refute_received {_, {:exit_status, _}}
  end

  test "decodes a JPEG 2000 preview at a reduced resolution, with the full size" do
    jp2 = File.read!("test/fixtures/synthetic_grey.jp2")

    assert {:ok, %{width: 32, height: 24, full_width: 128, full_height: 96, pixels: pixels}} =
             Decoder.decode_preview(jp2, {30, 20})

    assert byte_size(pixels) == 32 * 24
    assert {:error, :invalid_jp2} = Decoder.decode_preview(@wsq, {30, 20})
  end

  test "reports a crashed helper instead of crashing the caller" do
    with_executable("test/support/fake_decoders/crash.sh")
    assert {:error, :decoder_crashed} = Decoder.decode(:wsq, @wsq)
  end

  test "kills a helper that does not answer in time" do
    with_executable("test/support/fake_decoders/hang.sh")
    assert {:error, :decoder_timeout} = Decoder.decode(:wsq, @wsq, timeout: 200)
  end

  test "maps decoder errors to atoms" do
    assert {:error, :invalid_wsq} = Decoder.decode(:wsq, "junk")

    assert {:error, :not_lossless_jpeg} =
             Decoder.decode(
               :jpegl,
               <<0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0>>
             )
  end

  test "returns an error for every input the fuzzer found crashing NBIS" do
    for path <- Path.wildcard("native/nist_codecs/fuzz/regressions/*/*") do
      format = path |> Path.dirname() |> Path.basename() |> String.to_existing_atom()
      assert {:error, _} = Decoder.decode(format, File.read!(path)), path
    end
  end
end
