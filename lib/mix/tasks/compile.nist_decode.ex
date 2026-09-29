defmodule Mix.Tasks.Compile.NistDecode do
  @shortdoc "Builds the nist_decode helper into priv/native"

  @moduledoc """
  Builds `native/nist_decode` (the out-of-process image decoder, see
  `NistView.Decoder`) with Cargo and copies the executable to
  `priv/native/`. Listed after `:elixir` in the project's compilers, so it
  runs on every `mix compile`; Cargo makes an unchanged build a no-op.
  """

  use Mix.Task.Compiler

  @crate "native/nist_decode"

  @impl Mix.Task.Compiler
  def run(_args) do
    manifest = Path.join(@crate, "Cargo.toml")

    case System.cmd("cargo", ["build", "--release", "--quiet", "--manifest-path", manifest],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        copy_executable()
        {:ok, []}

      {output, status} ->
        Mix.shell().error(output)
        Mix.raise("Building #{@crate} failed (cargo exit status #{status})")
    end
  end

  defp copy_executable do
    name = if match?({:win32, _}, :os.type()), do: "nist_decode.exe", else: "nist_decode"
    source = Path.join([@crate, "target", "release", name])
    target_dir = Path.join(Mix.Project.app_path(), "priv/native")
    target = Path.join(target_dir, name)

    File.mkdir_p!(target_dir)

    unless File.exists?(target) and File.stat!(target).mtime >= File.stat!(source).mtime do
      File.cp!(source, target)
      File.chmod!(target, 0o755)
    end
  end
end
