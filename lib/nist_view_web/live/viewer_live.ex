defmodule NistViewWeb.ViewerLive do
  @moduledoc """
  The viewer: open an ANSI/NIST-ITL file, browse its records and fields,
  and look at its images with the minutiae overlaid.

  The file stays in this process's memory. Rendered images go to
  `NistView.ImageStore`, owned by this process, and are served by token.
  """

  use NistViewWeb, :live_view

  import NistViewWeb.ViewerComponents

  alias NistView.{Field, FieldNames, ImageStore, Imaging, Parser, Record, Viewer}
  alias NistViewWeb.MemoryUploadWriter

  @max_file_size 1_000_000_000
  @hex_page_bytes 4096

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Open a file", generation: 0)
     |> reset_file()
     |> allow_upload(:transaction,
       accept: :any,
       max_entries: 1,
       max_file_size: @max_file_size,
       auto_upload: true,
       writer: fn _name, _entry, _socket -> {MemoryUploadWriter, []} end,
       progress: &handle_progress/3
     )}
  end

  defp reset_file(socket) do
    socket
    |> assign(
      file: nil,
      data: nil,
      name: nil,
      error: nil,
      summary: nil,
      selected: nil,
      record: nil,
      view: :record,
      tab: :fields,
      renders: %{},
      tenprint: %{},
      minutiae: [],
      hex: nil,
      hex_page: 0,
      hex_pages: 0
    )
    |> stream(:records, [], reset: true)
    |> stream(:fields, [], reset: true)
    |> stream(:hex, [], reset: true)
  end

  # -- Opening a file ----------------------------------------------------------

  # Development only (see config/dev.exs): /?path=/some/file.an2
  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    if connected?(socket) and Application.get_env(:nist_view, :open_path_param, false) do
      case File.read(path) do
        {:ok, data} ->
          {:noreply, open_file(socket, Path.basename(path), data)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not read #{path}: #{reason}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp handle_progress(:transaction, entry, socket) do
    if entry.done? do
      data = consume_uploaded_entry(socket, entry, fn %{data: data} -> {:ok, data} end)
      {:noreply, open_file(socket, entry.client_name, data)}
    else
      {:noreply, socket}
    end
  end

  defp open_file(socket, name, data) do
    ImageStore.delete_owner(self())

    {file, error} =
      case Parser.parse(data) do
        {:ok, file} -> {file, nil}
        {:error, error, file} -> {file, error}
      end

    socket =
      socket
      |> reset_file()
      |> assign(
        page_title: name,
        generation: socket.assigns.generation + 1,
        file: file,
        data: data,
        name: name,
        error: error,
        summary: Viewer.summary(file),
        tenprint: Viewer.tenprint(file)
      )

    first = Enum.find_index(file.records, & &1.image) || 0

    socket =
      stream(socket, :records, Enum.map(Enum.with_index(file.records), &record_item(&1, first)),
        reset: true
      )

    # The items were just streamed with the selection, so they are not re-inserted:
    # an insert in the same render as a reset would move the item to the end.
    if file.records == [], do: socket, else: select(socket, first, restream: false)
  end

  defp record_item({%Record{} = record, index}, selected) do
    %{
      id: index,
      index: index,
      type: record.type,
      idc: record.idc,
      title: Viewer.title(record),
      subtitle: Viewer.image_summary(record),
      selected?: index == selected
    }
  end

  # -- Selection ---------------------------------------------------------------

  defp select(socket, index, opts \\ []) do
    %{file: file, selected: previous} = socket.assigns
    record = Enum.at(file.records, index)
    changed = if Keyword.get(opts, :restream, true), do: Enum.uniq([previous, index]), else: []

    socket =
      changed
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(socket, fn i, acc ->
        stream_insert(acc, :records, record_item({Enum.at(file.records, i), i}, index))
      end)

    socket
    |> assign(
      selected: index,
      record: record,
      minutiae: Viewer.minutiae_for(file, index)
    )
    |> stream(:fields, field_items(record, index), reset: true)
    |> set_hex({:record, index})
    |> ensure_render(index)
  end

  defp field_items(%Record{} = record, index) do
    for %Field{} = field <- record.fields do
      %{
        id: "#{index}-#{field.number}",
        tag:
          "#{record.type}.#{field.number |> Integer.to_string() |> String.pad_leading(3, "0")}",
        number: field.number,
        name: FieldNames.field(record.type, field.number),
        binary?: Field.binary?(field),
        size: byte_size(field.value),
        subfields: field.subfields
      }
    end
  end

  # -- Images ------------------------------------------------------------------

  defp ensure_render(socket, index) do
    %{file: file, renders: renders, generation: generation} = socket.assigns

    case Enum.at(file.records, index) do
      %Record{image: image} when not is_nil(image) and not is_map_key(renders, index) ->
        socket
        |> assign(renders: Map.put(renders, index, %{status: :loading}))
        |> start_async({:render, generation, index}, fn -> Imaging.displayable(image) end)

      _ ->
        socket
    end
  end

  @impl true
  def handle_async({:render, generation, index}, result, socket) do
    if generation == socket.assigns.generation do
      render = render_result(result)
      {:noreply, assign(socket, renders: Map.put(socket.assigns.renders, index, render))}
    else
      {:noreply, socket}
    end
  end

  defp render_result({:ok, {:ok, mime, bytes}}) do
    %{status: :ok, url: ~p"/render/#{ImageStore.put(self(), mime, bytes)}"}
  end

  defp render_result({:ok, {:error, reason}}),
    do: %{status: :error, error: Viewer.describe(reason)}

  defp render_result({:exit, reason}),
    do: %{status: :error, error: "decoder crashed: #{inspect(reason)}"}

  # -- Hex ---------------------------------------------------------------------

  defp set_hex(socket, target, page \\ 0) do
    {bytes, base} = hex_bytes(socket.assigns, target)
    pages = max(div(byte_size(bytes) + @hex_page_bytes - 1, @hex_page_bytes), 1)
    page = page |> max(0) |> min(pages - 1)
    start = page * @hex_page_bytes
    chunk = binary_part(bytes, start, min(@hex_page_bytes, byte_size(bytes) - start))

    lines =
      for {offset, hex, ascii} <- Viewer.hex_lines(chunk, base + start),
          do: %{id: offset, offset: offset, hex: hex, ascii: ascii}

    socket
    |> assign(hex: target, hex_page: page, hex_pages: pages)
    |> stream(:hex, lines, reset: true)
  end

  # Offsets are file offsets for a record, and field-relative for a field.
  defp hex_bytes(%{data: data, file: file}, {:record, index}) do
    record = Enum.at(file.records, index)
    {binary_part(data, record.offset, record.length), record.offset}
  end

  defp hex_bytes(%{file: file}, {:field, index, number}) do
    {Record.value(Enum.at(file.records, index), number) || <<>>, 0}
  end

  # -- Events ------------------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("select", %{"index" => index}, socket) do
    {:noreply, socket |> assign(view: :record) |> select(String.to_integer(index))}
  end

  def handle_event("key", %{"key" => key}, %{assigns: %{file: %{records: records}}} = socket)
      when key in ["ArrowDown", "ArrowUp", "j", "k"] do
    step = if key in ["ArrowDown", "j"], do: 1, else: -1
    index = ((socket.assigns.selected || 0) + step) |> max(0) |> min(length(records) - 1)
    {:noreply, if(index == socket.assigns.selected, do: socket, else: select(socket, index))}
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  def handle_event("view", %{"view" => "tenprint"}, socket) do
    socket = Enum.reduce(Map.values(socket.assigns.tenprint), socket, &ensure_render(&2, &1))
    {:noreply, assign(socket, view: :tenprint)}
  end

  def handle_event("view", %{"view" => "record"}, socket),
    do: {:noreply, assign(socket, view: :record)}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["fields", "hex"] do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_event("hex_field", %{"number" => number}, socket) do
    target = {:field, socket.assigns.selected, String.to_integer(number)}
    {:noreply, socket |> set_hex(target) |> assign(tab: :hex)}
  end

  def handle_event("hex_record", _params, socket) do
    {:noreply, socket |> set_hex({:record, socket.assigns.selected}) |> assign(tab: :hex)}
  end

  def handle_event("hex_page", %{"page" => page}, socket) do
    {:noreply, set_hex(socket, socket.assigns.hex, String.to_integer(page))}
  end

  def handle_event("close", _params, socket) do
    ImageStore.delete_owner(self())
    {:noreply, socket |> reset_file() |> assign(page_title: "Open a file")}
  end

  # -- Rendering ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="viewer-root"
        class="flex min-h-0 flex-1 flex-col"
        phx-drop-target={@uploads.transaction.ref}
        phx-window-keydown={@file && "key"}
      >
        <.top_bar
          name={@name}
          summary={@summary}
          file={@file}
          view={@view}
          tenprint={@tenprint}
          upload={@uploads.transaction}
        />

        <%= if @file do %>
          <div class="flex min-h-0 flex-1">
            <.sidebar streams={@streams} file={@file} error={@error} />

            <main class="flex min-w-0 flex-1 flex-col">
              <.tenprint_card
                :if={@view == :tenprint}
                file={@file}
                tenprint={@tenprint}
                renders={@renders}
              />
              <%!-- Kept in the DOM while hidden: stream items are not re-sent. --%>
              <div class={["flex min-h-0 flex-1 flex-col", @view != :record && "hidden"]}>
                <.record_view
                  record={@record}
                  selected={@selected}
                  render={@renders[@selected]}
                  minutiae={@minutiae}
                  streams={@streams}
                  tab={@tab}
                  hex={@hex}
                  hex_page={@hex_page}
                  hex_pages={@hex_pages}
                />
              </div>
            </main>
          </div>
        <% else %>
          <.empty_state upload={@uploads.transaction} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
