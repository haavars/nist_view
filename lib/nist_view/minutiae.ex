defmodule NistView.Minutiae do
  @moduledoc """
  Decodes the minutiae blocks of a Type-9 record into one representation.

  Four blocks are supported, each with its own units and conventions. The
  conventions below were derived by comparing the three blocks that NIST's
  BioCTS samples encode for the same print (`pass-type-9-14-m1.an2`,
  `pass-type-9-10-14.an2`, `pass-type-9-4-iafis.an2`), not taken on trust:

  | Block | Fields | Position units | Origin | Angle |
  |---|---|---|---|---|
  | `:m1` INCITS 378 | 9.137 FMD, 9.139 CIN, 9.140 DIN | pixels at 9.130–9.132 | top-left | 2° units |
  | `:standard` legacy | 9.012 MRC, 9.008 CRP, 9.009 DLT | 0.01 mm | bottom-left | degrees, M1 − 180° |
  | `:fbi` IAFIS | 9.023, 9.021, 9.022 | 0.01 mm | top-left | degrees, as M1 |
  | `:efs` Extended Feature Set | 9.331 MIN, 9.320 COR, 9.321 DEL | 0.01 mm | top-left | degrees, assumed as M1 |

  Decoded positions are in millimetres from the block's origin. Angles are
  normalised to the M1 convention: degrees counter-clockwise from the
  positive x axis as displayed. The EFS angle convention is not verified
  against an independent file: no sample with EFS minutiae is available,
  and abis_next's EFS writer passes `mindtct` angles through unchanged.

  `to_pixels/3` converts to an image's pixel grid with a top-left origin,
  which the overlay needs.
  """

  alias NistView.{Field, Record}

  @type point :: %{
          index: non_neg_integer() | nil,
          x: float(),
          y: float(),
          angle: float() | nil,
          type: :ridge_ending | :bifurcation | :other | nil,
          type_code: String.t() | nil,
          quality: integer() | nil
        }

  @type t :: %__MODULE__{
          format: :m1 | :standard | :fbi | :efs,
          units: :mm | :px,
          origin: :top_left | :bottom_left,
          minutiae: [point()],
          cores: [point()],
          deltas: [point()]
        }

  defstruct [:format, units: :mm, origin: :top_left, minutiae: [], cores: [], deltas: []]

  @doc """
  Decodes every supported minutiae block in a Type-9 record. A record may
  hold more than one block (e.g. legacy and EFS), so this returns a list.
  Malformed entries are skipped.
  """
  @spec decode(Record.t()) :: [t()]
  def decode(%Record{type: 9} = record) do
    [m1(record), standard(record), fbi(record), efs(record)]
    |> Enum.reject(&(is_nil(&1) or &1.minutiae ++ &1.cores ++ &1.deltas == []))
  end

  def decode(%Record{}), do: []

  @doc """
  Converts positions to pixels of an image with `ppi` resolution and
  `height` rows, with the origin at the top left.
  """
  @spec to_pixels(t(), number(), number()) :: t()
  def to_pixels(%__MODULE__{units: :mm} = set, ppi, height) do
    scale = ppi / 25.4

    convert = fn point ->
      y = point.y * scale
      %{point | x: point.x * scale, y: if(set.origin == :bottom_left, do: height - y, else: y)}
    end

    %{
      set
      | units: :px,
        origin: :top_left,
        minutiae: Enum.map(set.minutiae, convert),
        cores: Enum.map(set.cores, convert),
        deltas: Enum.map(set.deltas, convert)
    }
  end

  # -- INCITS 378 (M1) ---------------------------------------------------------

  defp m1(record) do
    with %Field{} <- Record.field(record, 137) || Record.field(record, 139),
         mm_per_px when is_float(mm_per_px) <- m1_scale(record) do
      point = fn x, y ->
        with {:ok, x} <- int(x), {:ok, y} <- int(y), do: {:ok, x * mm_per_px, y * mm_per_px}
      end

      minutiae =
        subfields(record, 137, fn
          [index, x, y, angle, type, quality | _] ->
            with {:ok, x, y} <- point.(x, y), {:ok, angle} <- int(angle) do
              %{
                index: int!(index),
                x: x,
                y: y,
                angle: angle * 2.0,
                type: m1_type(type),
                type_code: type,
                quality: int!(quality)
              }
            end

          _ ->
            nil
        end)

      singular = fn
        [x, y | rest] ->
          with {:ok, x, y} <- point.(x, y) do
            angle = with [a | _] <- rest, {:ok, a} <- int(a), do: a * 2.0, else: (_ -> nil)
            singular_point(x, y, angle)
          end

        _ ->
          nil
      end

      %__MODULE__{
        format: :m1,
        minutiae: minutiae,
        cores: subfields(record, 139, singular),
        deltas: subfields(record, 140, singular)
      }
    else
      _ -> nil
    end
  end

  # 9.130 SLC: 1 = pixels per inch, 2 = pixels per centimetre.
  defp m1_scale(record) do
    case {Record.value(record, 130), int(Record.value(record, 131))} do
      {"1", {:ok, ppi}} when ppi > 0 -> 25.4 / ppi
      {"2", {:ok, ppcm}} when ppcm > 0 -> 10 / ppcm
      _ -> nil
    end
  end

  defp m1_type("1"), do: :ridge_ending
  defp m1_type("2"), do: :bifurcation
  defp m1_type(_), do: :other

  # -- Legacy standard and FBI/IAFIS ---------------------------------------------

  defp standard(record) do
    packed_block(record, :standard, {12, 8, 9}, :bottom_left, 180)
  end

  defp fbi(record) do
    packed_block(record, :fbi, {23, 21, 22}, :top_left, 0)
  end

  # Both blocks pack position and direction as XXXXYYYYTTT in 0.01 mm and
  # degrees: index | XXXXYYYYTTT | quality | type | ridge counts...
  defp packed_block(record, format, {min_field, core_field, delta_field}, origin, rotate) do
    if Record.field(record, min_field) do
      minutiae =
        subfields(record, min_field, fn
          [index, packed, quality, type | _] ->
            with {:ok, x, y, angle} <- unpack(packed) do
              %{
                index: int!(index),
                x: x,
                y: y,
                angle: rem(angle + rotate, 360) * 1.0,
                type: letter_type(type),
                type_code: type,
                quality: int!(quality)
              }
            end

          _ ->
            nil
        end)

      singular = fn
        [packed | _] ->
          with {:ok, x, y} <- unpack_position(packed), do: singular_point(x, y, nil)

        _ ->
          nil
      end

      %__MODULE__{
        format: format,
        origin: origin,
        minutiae: minutiae,
        cores: subfields(record, core_field, singular),
        deltas: subfields(record, delta_field, singular)
      }
    end
  end

  defp unpack(<<x::binary-4, y::binary-4, angle::binary-3>>) do
    with {:ok, x, y} <- unpack_position(x <> y),
         {:ok, angle} <- int(angle),
         do: {:ok, x, y, angle}
  end

  defp unpack(_), do: :error

  defp unpack_position(<<x::binary-4, y::binary-4>>) do
    with {:ok, x} <- int(x), {:ok, y} <- int(y), do: {:ok, x / 100, y / 100}
  end

  defp unpack_position(_), do: :error

  # A = ridge ending, B = bifurcation. The other letters mark compound or
  # undetermined minutiae: for the same BioCTS print, M1 says 0 (other),
  # the legacy block D and the FBI block C.
  defp letter_type("A"), do: :ridge_ending
  defp letter_type("B"), do: :bifurcation
  defp letter_type(_), do: :other

  # -- Extended Feature Set --------------------------------------------------------

  defp efs(record) do
    if Record.field(record, 331) || Record.field(record, 320) || Record.field(record, 321) do
      point = fn x, y ->
        with {:ok, x} <- int(x), {:ok, y} <- int(y), do: {:ok, x / 100, y / 100}
      end

      minutiae =
        subfields(record, 331, fn
          [x, y, angle, type | _] ->
            with {:ok, x, y} <- point.(x, y), {:ok, angle} <- int(angle) do
              %{
                index: nil,
                x: x,
                y: y,
                angle: rem(angle, 360) * 1.0,
                type: efs_type(type),
                type_code: type,
                quality: nil
              }
            end

          _ ->
            nil
        end)

      singular = fn
        [x, y | _] -> with {:ok, x, y} <- point.(x, y), do: singular_point(x, y, nil)
        _ -> nil
      end

      %__MODULE__{
        format: :efs,
        minutiae: minutiae,
        cores: subfields(record, 320, singular),
        deltas: subfields(record, 321, singular)
      }
    end
  end

  # E = ridge ending, B = bifurcation, X = either (no distinction).
  defp efs_type("E"), do: :ridge_ending
  defp efs_type("B"), do: :bifurcation
  defp efs_type(_), do: :other

  # -- Helpers ---------------------------------------------------------------------

  defp singular_point(x, y, angle) do
    %{index: nil, x: x, y: y, angle: angle, type: nil, type_code: nil, quality: nil}
  end

  # Applies `fun` to each subfield's items, dropping those it returns nil or
  # an error for.
  defp subfields(record, number, fun) do
    case Record.field(record, number) do
      %Field{subfields: subfields} when is_list(subfields) ->
        subfields
        |> Enum.map(fun)
        |> Enum.filter(&is_map/1)

      _ ->
        []
    end
  end

  defp int(nil), do: :error

  defp int(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp int!(value) do
    case int(value) do
      {:ok, int} -> int
      :error -> nil
    end
  end
end
