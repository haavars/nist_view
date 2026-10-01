defmodule NistView.Decoder do
  @moduledoc """
  Decodes WSQ, lossless JPEG and JPEG 2000 in a separate OS process.

  The files are untrusted. All three decoders are safe Rust, so a hostile
  file cannot corrupt memory. It can still make a decoder panic, run out of
  memory or take too long, and inside a NIF that would take the whole BEAM
  with it. In the `nist_decode` helper (`native/nist_decode`) it only ends
  that process, which is reported as `{:error, :decoder_crashed}` or
  `{:error, :decoder_timeout}`. (The decoders were C at first: NBIS for WSQ
  and lossless JPEG, in which fuzzing found memory errors, and OpenJPEG for
  JPEG 2000.)

  Each call starts a helper, sends the image, waits for the pixels and
  closes it. A helper that takes longer than the timeout is killed.

  Results have the same shape as `NistView.Codecs` decoders.
  """

  @formats %{wsq: ?W, jpegl: ?L, jp2: ?J}

  @errors Map.new(
            ~w(invalid_wsq invalid_jpegl invalid_jp2 not_lossless_jpeg
               unsupported_colorspace too_large invalid_dimensions unknown_format)a,
            &{Atom.to_string(&1), &1}
          )

  @colorspaces %{?G => :gray, ?R => :srgb, ?Y => :sycc, ?U => :unspecified}

  @default_timeout 60_000

  @doc """
  Decodes `data` as `format` (`:wsq`, `:jpegl` or `:jp2`).

  Options: `:timeout` in milliseconds (default 60 s).
  """
  @spec decode(:wsq | :jpegl | :jp2, binary(), keyword()) ::
          {:ok, NistView.Codecs.decoded()} | {:error, atom()}
  def decode(format, data, opts \\ []) when is_map_key(@formats, format) and is_binary(data) do
    request(<<@formats[format]>>, data, opts)
  end

  @doc """
  Decodes a JPEG 2000 image at a reduced resolution, which is much faster
  for a large one: the smallest power-of-two reduction that is still at
  least `{width, height}`. The result also has the full size, as
  `:full_width` and `:full_height`; images that cannot be reduced come at
  full size.

  Options as for `decode/3`.
  """
  @spec decode_preview(binary(), {pos_integer(), pos_integer()}, keyword()) ::
          {:ok, map()} | {:error, atom()}
  def decode_preview(data, {width, height}, opts \\ []) when is_binary(data) do
    request(<<?P, width::32, height::32>>, data, opts)
  end

  defp request(header, data, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    port =
      Port.open({:spawn_executable, executable()}, [
        :binary,
        :exit_status,
        :use_stdio,
        packet: 4
      ])

    Port.command(port, [header, data])

    receive do
      {^port, {:data, reply}} ->
        close(port)
        parse(reply)

      {^port, {:exit_status, _status}} ->
        {:error, :decoder_crashed}
    after
      timeout ->
        kill(port)
        {:error, :decoder_timeout}
    end
  end

  @doc "The path of the helper executable (`:decoder_executable` overrides it, for tests)."
  @spec executable() :: String.t()
  def executable do
    Application.get_env(:nist_view, :decoder_executable) || default_executable()
  end

  defp default_executable do
    name = if match?({:win32, _}, :os.type()), do: "nist_decode.exe", else: "nist_decode"
    Path.join([:code.priv_dir(:nist_view), "native", name])
  end

  defp parse(<<?O, w::32, h::32, channels::32, ppi::32, cs, pixels::binary>>) do
    {:ok,
     %{
       width: w,
       height: h,
       channels: channels,
       bit_depth: 8,
       ppi: if(ppi > 0, do: ppi),
       colorspace: Map.fetch!(@colorspaces, cs),
       pixels: pixels
     }}
  end

  defp parse(<<?P, full_width::32, full_height::32, rest::binary>>) do
    with {:ok, decoded} <- parse(<<?O, rest::binary>>) do
      {:ok, Map.merge(decoded, %{full_width: full_width, full_height: full_height})}
    end
  end

  defp parse(<<?E, name::binary>>), do: {:error, Map.get(@errors, name, :decoder_error)}
  defp parse(_reply), do: {:error, :decoder_error}

  # Closing stdin ends the helper; its exit status message is flushed.
  defp close(port) do
    Port.close(port)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      0 -> :ok
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        Port.close(port)
        kill_os_process(pid)

      nil ->
        :ok
    end
  end

  defp kill_os_process(pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/PID", to_string(pid)], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
    end
  end
end
