defmodule NistView.Field do
  @moduledoc """
  One field of a record.

  `value` is the raw field content: text with separators still in it, or
  the image bytes for a binary field. `subfields` splits text on RS
  (0x1E) and then US (0x1F); it is nil for binary content.
  """

  @type t :: %__MODULE__{
          number: non_neg_integer(),
          value: binary(),
          subfields: [[binary()]] | nil
        }

  # The value can be personal data (Type-2 text) or image bytes, and must
  # not end up in logs or crash reports.
  @derive {Inspect, only: [:number]}
  defstruct [:number, :value, :subfields]

  @rs <<0x1E>>
  @us <<0x1F>>

  @doc "Builds a text field, splitting its value into subfields and items."
  @spec text(non_neg_integer(), binary()) :: t()
  def text(number, value) do
    subfields =
      value
      |> :binary.split(@rs, [:global])
      |> Enum.map(&:binary.split(&1, @us, [:global]))

    %__MODULE__{number: number, value: value, subfields: subfields}
  end

  @doc "Builds a field whose content is binary data."
  @spec binary(non_neg_integer(), binary()) :: t()
  def binary(number, value), do: %__MODULE__{number: number, value: value}

  @doc "Whether the field holds binary data rather than text."
  @spec binary?(t()) :: boolean()
  def binary?(%__MODULE__{subfields: nil}), do: true
  def binary?(%__MODULE__{}), do: false
end
