defmodule NistView.ImageStoreTest do
  use ExUnit.Case, async: true

  alias NistView.ImageStore

  test "stores and returns images by token" do
    token = ImageStore.put(self(), "image/png", "bytes")

    assert ImageStore.get(token) == {"image/png", "bytes"}
    assert ImageStore.get("unknown") == nil
    assert byte_size(token) >= 32
  end

  test "drops an owner's images when it exits" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    token = ImageStore.put(owner, "image/png", "bytes")
    ref = Process.monitor(owner)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

    # The store handles the owner's DOWN before this call.
    _ = :sys.get_state(ImageStore)
    assert ImageStore.get(token) == nil
  end

  test "drops an owner's images on request" do
    token = ImageStore.put(self(), "image/png", "bytes")
    other = ImageStore.put(spawn(fn -> Process.sleep(:infinity) end), "image/png", "kept")

    assert :ok = ImageStore.delete_owner(self())
    assert ImageStore.get(token) == nil
    assert ImageStore.get(other) == {"image/png", "kept"}
  end
end
