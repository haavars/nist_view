defmodule NistView.RedactionTest do
  use ExUnit.Case, async: true

  alias NistView.Parser

  # Field values and image bytes are personal data; they must not show up
  # when a struct is inspected, as it is in logs and crash reports.
  test "inspecting a parsed file shows no field values or image bytes" do
    {:ok, file} = Parser.parse(File.read!("test/fixtures/phantom_enrol.an2"))
    inspected = inspect(file, limit: :infinity, printable_limit: :infinity)

    # Text of Type-1 and Type-2; short values such as "175" also occur as offsets.
    for %{type: type} = record <- file.records,
        type in [1, 2],
        field <- record.fields,
        byte_size(field.value) >= 5 do
      refute inspected =~ field.value
    end

    assert inspected =~ "#NistView.Field<number: 4"
    assert inspected =~ "#NistView.ImageRef<"
    refute inspected =~ "data:"
  end
end
