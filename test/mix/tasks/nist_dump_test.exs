defmodule Mix.Tasks.Nist.DumpTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import NistView.NistBuilder

  @wsq File.read!("test/fixtures/synthetic.wsq")

  @moduletag :tmp_dir

  defp write_sample(dir) do
    type2 = tagged(2, [{2, "0"}, {3, "SYNTHETIC"}])
    type4 = type4(1, fgp: [1], hll: 128, vll: 96, gca: 1, data: @wsq)
    path = Path.join(dir, "sample.an2")
    File.write!(path, transaction([{2, 0, type2}, {4, 1, type4}]))
    path
  end

  test "prints every record and field", %{tmp_dir: dir} do
    output = capture_io(fn -> Mix.Tasks.Nist.Dump.run([write_sample(dir)]) end)

    assert output =~ "3 records"
    assert output =~ "Type-1  Transaction information"
    assert output =~ ~r/1\.002 VER\s+0502/
    assert output =~ ~r/2\.003\s+SYNTHETIC/
    assert output =~ "Type-4  High-resolution grayscale fingerprint  IDC 1"
    assert output =~ ~r/4\.009 DATA\s+<#{byte_size(@wsq)} bytes>/
    assert output =~ "image: wsq (1)  128×96  500 ppi  8-bit"
    refute output =~ "displayable"
  end

  test "--decode decodes images and --png writes them", %{tmp_dir: dir} do
    out_dir = Path.join(dir, "png")

    output =
      capture_io(fn ->
        Mix.Tasks.Nist.Dump.run([write_sample(dir), "--decode", "--png", out_dir])
      end)

    assert output =~ "displayable as image/png"
    assert [png] = File.ls!(out_dir)
    assert <<0x89, "PNG", _::binary>> = File.read!(Path.join(out_dir, png))
  end

  test "prints the parsed records and exits with status 1 on a parse error", %{tmp_dir: dir} do
    path = write_sample(dir)
    File.write!(path, binary_part(File.read!(path), 0, 400))

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Nist.Dump.run([path])) == {:shutdown, 1}
        end)
      end)

    assert output =~ "Type-2"
    refute output =~ "Type-4"
  end
end
