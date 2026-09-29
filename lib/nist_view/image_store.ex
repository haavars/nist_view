defmodule NistView.ImageStore do
  @moduledoc """
  Holds rendered images in memory so the browser can load them by URL.

  Each image gets a random, unguessable token and belongs to an owner
  process (a viewer LiveView). When the owner exits, its images are
  dropped. Nothing is written to disk.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stores `bytes` for `owner` and returns the token to fetch them with."
  @spec put(pid(), String.t(), binary()) :: String.t()
  def put(owner, mime, bytes) when is_pid(owner) and is_binary(bytes) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ok = GenServer.call(__MODULE__, {:put, owner, token, mime, bytes})
    token
  end

  @doc "Returns `{mime, bytes}` for a token, or nil."
  @spec get(String.t()) :: {String.t(), binary()} | nil
  def get(token) when is_binary(token) do
    case :ets.lookup(@table, token) do
      [{^token, _owner, mime, bytes}] -> {mime, bytes}
      [] -> nil
    end
  end

  @doc "Drops every image of `owner`."
  @spec delete_owner(pid()) :: :ok
  def delete_owner(owner), do: GenServer.call(__MODULE__, {:delete_owner, owner})

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:put, owner, token, mime, bytes}, _from, state) do
    :ets.insert(@table, {token, owner, mime, bytes})
    {:reply, :ok, monitor(state, owner)}
  end

  def handle_call({:delete_owner, owner}, _from, state) do
    :ets.match_delete(@table, {:_, owner, :_, :_})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    :ets.match_delete(@table, {:_, owner, :_, :_})
    {:noreply, %{state | monitors: Map.delete(state.monitors, owner)}}
  end

  defp monitor(%{monitors: monitors} = state, owner) do
    if Map.has_key?(monitors, owner),
      do: state,
      else: %{state | monitors: Map.put(monitors, owner, Process.monitor(owner))}
  end
end
