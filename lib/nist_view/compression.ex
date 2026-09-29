defmodule NistView.Compression do
  @moduledoc """
  Maps the compression labels found in files to one codec atom each.

  Real files use older spellings than the 2011 tables, e.g. Prüm Type-13
  records say `WSQ` where the standard now says `WSQ20`.
  """

  @type t :: :raw | :wsq | :jpegb | :jpegl | :jp2 | :jp2l | :png | :unknown

  @labels %{
    "NONE" => :raw,
    "WSQ" => :wsq,
    "WSQ20" => :wsq,
    "JPEGB" => :jpegb,
    "JPEGL" => :jpegl,
    "JP2" => :jp2,
    "JP2L" => :jp2l,
    "PNG" => :png
  }

  # Type-4/5/6 GCA byte, as in the 2011 compression code table.
  @gca_codes %{0 => :raw, 1 => :wsq, 2 => :jpegb, 3 => :jpegl, 4 => :jp2, 5 => :jp2l, 6 => :png}

  @doc "Normalises a tagged record's `.011` compression label."
  @spec from_label(binary()) :: t()
  def from_label(label) when is_binary(label) do
    Map.get(@labels, label |> String.trim() |> String.upcase(), :unknown)
  end

  @doc "Normalises a legacy binary record's GCA byte."
  @spec from_gca(non_neg_integer()) :: t()
  def from_gca(code) when is_integer(code), do: Map.get(@gca_codes, code, :unknown)
end
