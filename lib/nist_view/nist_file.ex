defmodule NistView.NistFile do
  @moduledoc """
  A parsed ANSI/NIST-ITL transaction: its records in file order, plus
  anything odd the parser noticed without having to stop.

  `warnings` are `{offset, reason}` tuples, such as a record whose type
  differs from what Type-1 CNT announced.
  """

  alias NistView.Record

  @type warning :: {non_neg_integer(), term()}

  @type t :: %__MODULE__{
          size: non_neg_integer(),
          records: [Record.t()],
          warnings: [warning()]
        }

  defstruct size: 0, records: [], warnings: []
end
