defmodule NistView.Desktop do
  @moduledoc """
  The Elixir side of the desktop shell (`src-tauri`), which talks to it over
  `ElixirKit.PubSub`.

    * Once the endpoint is listening, broadcasts `ready:<url>` on the
      `messages` topic so the shell can open a window on the real port.
    * Receives `<id>\\n<path>` on the `open` topic when the shell is asked to
      open a file (file association, command line, second launch), and keeps
      the path under `id` until a viewer window claims it with `take/1`. The
      shell then opens a window on `/?open=<id>`.

  Only the shell can put paths here, so a web page cannot make the viewer
  read an arbitrary file.
  """

  use GenServer

  @table __MODULE__
  @topic "desktop:open"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the desktop shell started this node."
  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env("ELIXIRKIT_PUBSUB") != nil

  @doc """
  Subscribes the caller to the path for `id`, then returns it if it is
  already here. Otherwise the caller receives `{:desktop_open, id, path}`
  when it arrives. A path can be taken once.
  """
  @spec take(String.t()) :: {:ok, Path.t()} | :pending
  def take(id) when is_binary(id) do
    Phoenix.PubSub.subscribe(NistView.PubSub, "#{@topic}:#{id}")

    case :ets.whereis(@table) != :undefined and :ets.take(@table, id) do
      [{^id, path}] -> {:ok, path}
      _ -> :pending
    end
  end

  @doc "Drops the path for `id` after it arrived by message instead of `take/1`."
  @spec discard(String.t()) :: :ok
  def discard(id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, id)
    :ok
  end

  @doc "Records a path the shell asked to open. Public for tests."
  @spec put(String.t(), Path.t()) :: :ok
  def put(id, path), do: GenServer.call(__MODULE__, {:put, id, path})

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public])

    if Keyword.get(opts, :pubsub, true) do
      ElixirKit.PubSub.subscribe("open")
      {:ok, %{}, {:continue, :ready}}
    else
      {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_continue(:ready, state) do
    {:ok, {_ip, port}} = NistViewWeb.Endpoint.server_info(:http)
    ElixirKit.PubSub.broadcast("messages", "ready:http://127.0.0.1:#{port}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:put, id, path}, _from, state) do
    store(id, path)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(message, state) when is_binary(message) do
    case String.split(message, "\n", parts: 2) do
      [id, path] when id != "" and path != "" -> store(id, path)
      _ -> :ok
    end

    {:noreply, state}
  end

  defp store(id, path) do
    :ets.insert(@table, {id, path})
    Phoenix.PubSub.broadcast(NistView.PubSub, "#{@topic}:#{id}", {:desktop_open, id, path})
  end
end
