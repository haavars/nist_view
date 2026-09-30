defmodule NistView.LogRedaction do
  @moduledoc """
  Keeps file contents out of crash reports.

  When a process crashes, OTP logs its state, the message it was handling
  and the arguments of the function that failed. In this application any
  of those can hold a file's bytes, its Type-2 text or a rendered image: the
  viewer keeps the whole file in its assigns, a decoded image arrives as a
  message, and a failing call may have the file as an argument.

  This translator runs before `Logger.Translator` and hands it the report
  with those parts removed, so the crash is still logged with its exception,
  message and stack trace (functions and arities, no arguments). The
  exception itself can still contain data from the file (a `MatchError`
  on a field's value, say); structs that hold file contents therefore
  redact themselves in `inspect` (`NistView.Field`, `NistView.ImageRef`).

  Installed by `NistView.Application`.
  """

  @redacted :redacted

  @doc "A `Logger` translator (see `Logger.Translator`)."
  def translate(
        min_level,
        level,
        :report,
        {:logger, %{label: {:gen_server, :terminate}} = report}
      ) do
    report = %{
      report
      | state: @redacted,
        last_message: redact_message(report.last_message),
        reason: redact_reason(report.reason),
        client_info: redact_client(report.client_info)
    }

    Logger.Translator.translate(min_level, level, :report, {:logger, report})
  end

  def translate(min_level, level, :report, {{Task.Supervisor, :terminating} = label, report}) do
    report = %{report | args: @redacted, reason: redact_reason(report.reason)}
    Logger.Translator.translate(min_level, level, :report, {label, report})
  end

  def translate(_min_level, _level, _kind, _message), do: :none

  # The event name of a LiveView message is kept, its parameters are not.
  defp redact_message(%Phoenix.Socket.Message{payload: %{"event" => event}} = message),
    do: %{message | payload: %{"event" => event}}

  defp redact_message(%Phoenix.Socket.Message{} = message), do: %{message | payload: @redacted}

  defp redact_message(message) when is_tuple(message) and is_atom(elem(message, 0)),
    do: {elem(message, 0), @redacted}

  defp redact_message(_message), do: @redacted

  # The exception is normalised while the stack trace still has its
  # arguments, which some messages are built from (such as which argument
  # of a BIF was bad); the arguments are then replaced by the arity.
  defp redact_reason({reason, [_ | _] = stacktrace} = original) do
    if stacktrace?(stacktrace) do
      exception = if is_exception(reason), do: reason, else: normalize(reason, stacktrace)
      {exception, redact_stacktrace(stacktrace)}
    else
      original
    end
  end

  defp redact_reason(reason), do: reason

  defp normalize(reason, stacktrace) do
    case Exception.normalize(:error, reason, stacktrace) do
      # Not an error that maps to an exception, e.g. an exit reason: kept.
      %ErlangError{original: ^reason} -> reason
      exception -> exception
    end
  end

  defp redact_client({from, {name, stacktrace}}) when is_list(stacktrace),
    do: {from, {name, redact_stacktrace(stacktrace)}}

  defp redact_client(client), do: client

  defp redact_stacktrace(stacktrace) do
    for entry <- stacktrace do
      case entry do
        {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
        {fun, args, location} when is_list(args) -> {fun, length(args), location}
        entry -> entry
      end
    end
  end

  defp stacktrace?(stacktrace) do
    Enum.all?(stacktrace, fn
      {mod, fun, args, location} ->
        is_atom(mod) and is_atom(fun) and args_or_arity?(args) and is_list(location)

      {fun, args, location} ->
        is_function(fun) and args_or_arity?(args) and is_list(location)

      _ ->
        false
    end)
  end

  defp args_or_arity?(args), do: is_list(args) or is_integer(args)
end
