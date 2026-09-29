defmodule NistView.Positions do
  @moduledoc """
  Names of friction ridge positions (FGP), from the ANSI/NIST-ITL
  position code tables. Unlisted codes are shown by number.
  """

  @names %{
    0 => "Unknown finger",
    1 => "Right thumb",
    2 => "Right index",
    3 => "Right middle",
    4 => "Right ring",
    5 => "Right little",
    6 => "Left thumb",
    7 => "Left index",
    8 => "Left middle",
    9 => "Left ring",
    10 => "Left little",
    11 => "Plain right thumb",
    12 => "Plain left thumb",
    13 => "Plain right four fingers",
    14 => "Plain left four fingers",
    15 => "Left and right thumbs",
    20 => "Unknown palm",
    21 => "Right full palm",
    22 => "Right writer's palm",
    23 => "Left full palm",
    24 => "Left writer's palm",
    25 => "Right lower palm",
    26 => "Right upper palm",
    27 => "Left lower palm",
    28 => "Left upper palm",
    29 => "Right other",
    30 => "Left other"
  }

  @doc "The name of position `code`, or nil."
  @spec name(integer() | nil) :: String.t() | nil
  def name(code), do: Map.get(@names, code)
end
