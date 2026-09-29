defmodule NistView.ImageRef do
  @moduledoc """
  An image embedded in a record, still encoded.

  `data` is a sub-binary of the original file. `compression` is the
  normalised codec (see `NistView.Compression`); `label` is what the file
  actually said (the `.011` value, or the Type-4 GCA byte).
  """

  @type t :: %__MODULE__{
          compression: NistView.Compression.t(),
          label: String.t(),
          data: binary(),
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          ppi: non_neg_integer() | nil,
          bit_depth: non_neg_integer() | nil,
          colorspace: String.t() | nil
        }

  defstruct [:compression, :label, :data, :width, :height, :ppi, :bit_depth, :colorspace]
end
