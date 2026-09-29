defmodule NistView.ImageRef do
  @moduledoc """
  An image embedded in a record, still encoded.

  `data` is a sub-binary of the original file. `compression` is the
  normalised codec (see `NistView.Compression`); `label` is what the file
  actually said (the `.011` value, or the Type-4 GCA byte). `format` is
  what the data turned out to be (see `NistView.ImageFormat`), which
  decoding follows; it equals `compression` unless the bytes disagree
  with the label.
  """

  @type t :: %__MODULE__{
          compression: NistView.Compression.t(),
          format: NistView.Compression.t(),
          label: String.t(),
          data: binary(),
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          ppi: non_neg_integer() | nil,
          bit_depth: non_neg_integer() | nil,
          colorspace: String.t() | nil
        }

  defstruct [:compression, :format, :label, :data, :width, :height, :ppi, :bit_depth, :colorspace]
end
