defmodule NistViewWeb.MemoryUploadWriter do
  @moduledoc """
  Keeps an uploaded file in memory instead of LiveView's default temporary
  file, so a transaction opened in the browser never touches the disk.
  Consuming the entry yields `%{data: binary}`.
  """

  @behaviour Phoenix.LiveView.UploadWriter

  @impl true
  def init(_opts), do: {:ok, %{chunks: []}}

  @impl true
  def meta(%{chunks: chunks}), do: %{data: chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  @impl true
  def write_chunk(data, %{chunks: chunks} = state), do: {:ok, %{state | chunks: [data | chunks]}}

  @impl true
  def close(state, _reason), do: {:ok, state}
end
