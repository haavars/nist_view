defmodule NistView.LogRedactionTest do
  use ExUnit.Case, async: true

  alias NistView.{Field, ImageRef, LogRedaction}

  @secret "DOE^JANE"

  defp stacktrace do
    try do
      String.to_integer(Enum.random([@secret]))
    catch
      :error, :badarg -> __STACKTRACE__
    end
  end

  defp translate(message) do
    {:ok, chardata, _metadata} = LogRedaction.translate(:debug, :error, :report, message)
    IO.chardata_to_string(chardata)
  end

  test "a GenServer crash keeps the error and drops state, message and arguments" do
    report = %{
      label: {:gen_server, :terminate},
      name: self(),
      reason: {:badarg, stacktrace()},
      last_message: %Phoenix.Socket.Message{
        topic: "lv:1",
        event: "event",
        payload: %{"event" => "select", "value" => %{"index" => @secret}}
      },
      state: %{data: @secret},
      client_info: {self(), {self(), stacktrace()}},
      process_label: :undefined,
      log: []
    }

    log = translate({:logger, report})

    assert log =~ "not a textual representation of an integer"
    assert log =~ ":erlang.binary_to_integer/1"
    assert log =~ ~s("select")
    assert log =~ "State: :redacted"
    refute log =~ @secret
  end

  test "a Task crash keeps the error and drops the arguments" do
    report = %{
      name: self(),
      starter: self(),
      function: &String.to_integer/1,
      args: [@secret],
      reason: {:badarg, stacktrace()},
      process_label: :undefined
    }

    log = translate({{Task.Supervisor, :terminating}, report})

    assert log =~ "ArgumentError"
    refute log =~ @secret
  end

  test "other messages are left to the next translator" do
    assert LogRedaction.translate(:debug, :info, :format, {~c"~p", [@secret]}) == :none
  end

  test "fields and images do not show their contents when inspected" do
    refute inspect(Field.text(1, @secret)) =~ @secret
    refute inspect(Field.binary(999, @secret)) =~ @secret
    refute inspect(%ImageRef{data: @secret, width: 10}) =~ @secret
    assert inspect(%ImageRef{data: @secret, width: 10}) =~ "width: 10"
  end
end
