defmodule NistView.Record do
  @moduledoc """
  One logical record.

  `encoding` is `:tagged` for `T.NNN:value` records and `:binary` for the
  legacy fixed-layout records (Type-3 to Type-8). Binary records get
  synthetic fields numbered as in the standard (e.g. `4.001`–`4.009`), so
  both kinds display the same way.

  `offset` and `length` locate the record in the original file.
  """

  alias NistView.{Field, ImageRef}

  @type t :: %__MODULE__{
          type: non_neg_integer(),
          idc: non_neg_integer() | nil,
          encoding: :tagged | :binary,
          offset: non_neg_integer(),
          length: non_neg_integer(),
          fields: [Field.t()],
          image: ImageRef.t() | nil
        }

  defstruct [:type, :idc, :encoding, :offset, :length, fields: [], image: nil]

  @doc "Returns the field with `number`, or nil."
  @spec field(t(), pos_integer()) :: Field.t() | nil
  def field(%__MODULE__{fields: fields}, number), do: Enum.find(fields, &(&1.number == number))

  @doc "Returns the raw value of field `number`, or nil."
  @spec value(t(), pos_integer()) :: binary() | nil
  def value(record, number) do
    case field(record, number) do
      %Field{value: value} -> value
      nil -> nil
    end
  end
end
