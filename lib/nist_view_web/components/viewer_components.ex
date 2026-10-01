defmodule NistViewWeb.ViewerComponents do
  @moduledoc """
  Function components for `NistViewWeb.ViewerLive`.
  """

  use NistViewWeb, :html

  alias NistView.{NistFile, Positions, Record, Viewer}

  # -- Top bar -------------------------------------------------------------------

  attr :name, :string
  attr :summary, :map
  attr :file, :any
  attr :view, :atom
  attr :tenprint, :map
  attr :upload, :any, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="flex h-14 shrink-0 items-center gap-4 border-b border-white/[0.06] bg-zinc-925 px-4">
      <div class="flex shrink-0 items-center gap-2">
        <div class="grid size-7 place-items-center rounded-md bg-sky-500/15 ring-1 ring-sky-400/25">
          <.icon name="hero-finger-print" class="size-4.5 text-sky-300" />
        </div>
        <span class="text-sm font-semibold tracking-tight text-zinc-100">NIST Viewer</span>
      </div>

      <%= if @file do %>
        <div class="h-7 w-px shrink-0 bg-white/[0.08]" />
        <div class="min-w-0 flex-1">
          <p
            id="file-name"
            class="truncate text-[13px] leading-5 font-medium text-zinc-100"
            title={@name}
          >
            {@name}
          </p>
          <p
            id="file-facts"
            class="truncate text-[11px] leading-4 text-zinc-500"
            title={facts_title(@summary)}
          >
            <%= for {{label, value}, i} <- Enum.with_index(facts(@summary)) do %>
              <span :if={i > 0} class="px-1 text-zinc-700">·</span>
              <span>{label}</span> <span class="font-mono text-zinc-300">{value}</span>
            <% end %>
          </p>
        </div>

        <div class="flex shrink-0 items-center gap-2">
          <div
            :if={@tenprint != %{}}
            class="flex rounded-lg bg-white/[0.04] p-0.5 ring-1 ring-white/[0.06]"
          >
            <.segment id="view-record" active={@view == :record} value="record">Records</.segment>
            <.segment id="view-tenprint" active={@view == :tenprint} value="tenprint">
              Tenprint
            </.segment>
          </div>
          <.open_button upload={@upload} label="Open" />
          <button
            id="close-file"
            type="button"
            phx-click="close"
            class="grid size-8 place-items-center rounded-lg text-zinc-400 transition hover:bg-white/[0.06] hover:text-zinc-100"
            title="Close file"
            aria-label="Close file"
          >
            <.icon name="hero-x-mark" class="size-4.5" />
          </button>
        </div>
      <% end %>
    </header>
    """
  end

  # The Type-1 facts shown under the file name, in reading order.
  defp facts(summary) do
    [
      {"TOT", summary.tot},
      {"VER", summary.version},
      {"DAT", summary.date},
      {"TCN", summary.tcn},
      {"DOM", summary.domain}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
  end

  defp facts_title(summary),
    do: Enum.map_join(facts(summary), "\n", fn {label, value} -> "#{label}  #{value}" end)

  attr :id, :string, required: true
  attr :active, :boolean, required: true
  attr :value, :string, required: true
  slot :inner_block, required: true

  defp segment(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="view"
      phx-value-view={@value}
      class={[
        "rounded-md px-3 py-1 text-xs font-medium transition",
        if(@active,
          do: "bg-white/10 text-zinc-100 shadow-sm",
          else: "text-zinc-400 hover:text-zinc-200"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :upload, :any, required: true
  attr :label, :string, required: true
  attr :primary, :boolean, default: false

  defp open_button(assigns) do
    ~H"""
    <form id={"upload-form-#{@primary}"} phx-change="validate" phx-submit="validate" class="contents">
      <label class={[
        "inline-flex cursor-pointer items-center gap-2 rounded-lg font-medium transition",
        if(@primary,
          do:
            "bg-sky-500 px-4 py-2 text-sm text-white shadow-sm ring-1 ring-sky-300/30 ring-inset hover:bg-sky-400 active:scale-[0.98]",
          else:
            "bg-white/[0.06] px-3 py-1.5 text-xs text-zinc-200 ring-1 ring-white/[0.08] hover:bg-white/10"
        )
      ]}>
        <.icon name="hero-folder-open" class={if(@primary, do: "size-4.5", else: "size-4")} />
        {@label}
        <.live_file_input upload={@upload} class="sr-only" />
      </label>
    </form>
    """
  end

  # -- Empty state ---------------------------------------------------------------

  attr :upload, :any, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="grid flex-1 place-items-center p-8">
      <div
        id="drop-zone"
        class="group relative w-full max-w-xl rounded-2xl border border-dashed border-white/10 bg-zinc-925/60 p-12 text-center transition phx-drop-target-active:border-sky-400/70 phx-drop-target-active:bg-sky-500/[0.04]"
      >
        <div class="mx-auto mb-6 grid size-14 place-items-center rounded-xl bg-white/[0.04] ring-1 ring-white/[0.08] transition phx-drop-target-active:bg-sky-500/10 phx-drop-target-active:ring-sky-400/30">
          <.icon name="hero-document-arrow-up" class="size-7 text-zinc-400" />
        </div>
        <h1 class="text-xl font-semibold tracking-tight text-zinc-100">
          Open an ANSI/NIST-ITL file
        </h1>
        <p class="mt-2 text-sm text-zinc-400">
          Drop a <span class="font-mono text-zinc-300">.an2</span>,
          <span class="font-mono text-zinc-300">.nst</span>
          or <span class="font-mono text-zinc-300">.eft</span>
          file here, or choose one.
        </p>
        <div class="mt-8 flex justify-center">
          <.open_button upload={@upload} label="Choose file" primary />
        </div>

        <%= for entry <- @upload.entries do %>
          <div id={"upload-#{entry.ref}"} class="mx-auto mt-6 max-w-xs">
            <div class="mb-1.5 flex justify-between text-xs text-zinc-400">
              <span class="truncate">{entry.client_name}</span>
              <span class="tabular-nums">{entry.progress}%</span>
            </div>
            <div class="h-1 overflow-hidden rounded-full bg-white/[0.06]">
              <div
                class="h-full rounded-full bg-sky-400 transition-all"
                style={"width: #{entry.progress}%"}
              />
            </div>
            <p :for={err <- upload_errors(@upload, entry)} class="mt-2 text-xs text-rose-400">
              {upload_error(err)}
            </p>
          </div>
        <% end %>
        <p :for={err <- upload_errors(@upload)} class="mt-4 text-xs text-rose-400">
          {upload_error(err)}
        </p>

        <div class="mt-10 border-t border-white/[0.06] pt-5">
          <p class="flex items-center justify-center gap-1.5 text-xs text-zinc-500">
            <.icon name="hero-lock-closed" class="size-3.5" />
            The file stays in memory on this computer. Nothing is written to disk.
          </p>
          <p class="mt-2 text-[11px] text-zinc-600">
            Traditional encoding · WSQ, JPEG, JPEG 2000, lossless JPEG and PNG images
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp upload_error(:too_large), do: "The file is too large."
  defp upload_error(:too_many_files), do: "Open one file at a time."
  defp upload_error(other), do: "Upload failed: #{inspect(other)}"

  # -- Status bar ----------------------------------------------------------------

  attr :file, NistFile, required: true
  attr :error, :any

  def status_bar(assigns) do
    assigns =
      assign(assigns,
        images: Enum.count(assigns.file.records, & &1.image),
        warnings: length(assigns.file.warnings)
      )

    ~H"""
    <footer
      id="status-bar"
      class="flex h-7 shrink-0 items-center gap-4 border-t border-white/[0.06] bg-zinc-925 px-4 text-[11px] text-zinc-500"
    >
      <%= if @error do %>
        <span class="flex items-center gap-1.5 text-rose-300">
          <.icon name="hero-exclamation-triangle" class="size-3.5" />
          Parsing stopped at byte {elem(@error, 0)}
        </span>
      <% else %>
        <span class="flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-emerald-400" /> Parsed
        </span>
      <% end %>
      <span>{format_bytes(@file.size)}</span>
      <span>{plural(length(@file.records), "record")}</span>
      <span>{plural(@images, "image")}</span>
      <span :if={@warnings > 0} class="text-amber-300/90">{plural(@warnings, "warning")}</span>

      <span class="ml-auto flex items-center gap-1.5" title="Nothing from the file is written to disk">
        <.icon name="hero-lock-closed" class="size-3.5" /> In memory only
      </span>
      <button
        id="show-shortcuts"
        type="button"
        phx-click={show_shortcuts()}
        class="flex items-center gap-1.5 rounded px-1.5 py-0.5 transition hover:bg-white/[0.06] hover:text-zinc-200"
      >
        <kbd class="font-sans">?</kbd> Shortcuts
      </button>
    </footer>
    """
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  # -- Keyboard shortcuts ------------------------------------------------------------

  @shortcuts [
    {"Records",
     [{["↑", "↓"], "Previous or next record"}, {["J", "K"], "Next or previous record"}]},
    {"Image",
     [
       {["F"], "Fit to window"},
       {["1"], "Actual pixels"},
       {["2"], "Zoom to 2×"},
       {["+", "−"], "Zoom in or out"},
       {["I"], "Invert"},
       {["R"], "Reset display adjustments"},
       {["M"], "Show or hide minutiae"}
     ]},
    {"General", [{["?"], "Show these shortcuts"}, {["Esc"], "Close this panel"}]}
  ]

  def show_shortcuts(js \\ %JS{}) do
    js
    |> JS.show(
      to: "#shortcuts",
      display: "grid",
      transition: {"ease-out duration-150", "opacity-0", "opacity-100"}
    )
    |> JS.focus(to: "#shortcuts-close")
  end

  def hide_shortcuts(js \\ %JS{}) do
    JS.hide(js,
      to: "#shortcuts",
      transition: {"ease-in duration-100", "opacity-100", "opacity-0"}
    )
  end

  def shortcuts(assigns) do
    assigns = assign(assigns, groups: @shortcuts)

    ~H"""
    <div
      id="shortcuts"
      phx-hook=".Shortcuts"
      data-show={show_shortcuts()}
      class="fixed inset-0 z-50 hidden place-items-center bg-black/60 p-6 backdrop-blur-sm"
      phx-window-keydown={hide_shortcuts()}
      phx-key="Escape"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="shortcuts-title"
        phx-click-away={hide_shortcuts()}
        class="w-full max-w-md rounded-2xl bg-zinc-900 p-5 shadow-2xl ring-1 shadow-black/60 ring-white/10"
      >
        <div class="mb-4 flex items-center justify-between">
          <h2 id="shortcuts-title" class="text-sm font-semibold text-zinc-100">Keyboard shortcuts</h2>
          <button
            id="shortcuts-close"
            type="button"
            phx-click={hide_shortcuts()}
            aria-label="Close"
            class="grid size-7 place-items-center rounded-md text-zinc-400 transition hover:bg-white/[0.06] hover:text-zinc-100"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="space-y-4">
          <section :for={{group, keys} <- @groups}>
            <h3 class="mb-1.5 text-[11px] font-semibold tracking-wider text-zinc-500 uppercase">
              {group}
            </h3>
            <dl class="divide-y divide-white/[0.04]">
              <div :for={{combo, what} <- keys} class="flex items-center justify-between py-1.5">
                <dt class="text-xs text-zinc-300">{what}</dt>
                <dd class="flex gap-1">
                  <kbd
                    :for={key <- combo}
                    class="min-w-6 rounded-md bg-white/[0.06] px-1.5 py-0.5 text-center font-sans text-[11px] text-zinc-200 ring-1 ring-white/10"
                  >
                    {key}
                  </kbd>
                </dd>
              </div>
            </dl>
          </section>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Shortcuts">
        export default {
          mounted() {
            this.onKey = e => {
              if (e.key !== "?" || e.metaKey || e.ctrlKey || e.altKey) return
              if (["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName)) return
              e.preventDefault()
              this.liveSocket.execJS(this.el, this.el.dataset.show)
            }
            window.addEventListener("keydown", this.onKey)
          },
          destroyed() { window.removeEventListener("keydown", this.onKey) },
        }
      </script>
    </div>
    """
  end

  # -- Sidebar -------------------------------------------------------------------

  attr :streams, :any, required: true
  attr :file, NistFile, required: true
  attr :error, :any

  def sidebar(assigns) do
    ~H"""
    <aside id="sidebar" class="flex w-(--sidebar-w) shrink-0 flex-col bg-zinc-925">
      <div class="flex items-center justify-between px-4 pt-4 pb-2">
        <h2 class="text-[11px] font-semibold tracking-wider text-zinc-500 uppercase">Records</h2>
        <span class="text-[11px] tabular-nums text-zinc-500">{length(@file.records)}</span>
      </div>

      <div
        :if={@error}
        id="parse-error"
        class="mx-3 mb-2 rounded-lg bg-rose-500/10 px-3 py-2 text-xs text-rose-300 ring-1 ring-rose-500/20"
      >
        <div class="flex items-center gap-1.5 font-medium">
          <.icon name="hero-exclamation-triangle" class="size-4" /> Parsing stopped
        </div>
        <p class="mt-1 text-rose-300/80">
          At byte {elem(@error, 0)}: {Viewer.describe(elem(@error, 1))}.
        </p>
      </div>

      <nav
        id="records"
        phx-update="stream"
        class="min-h-0 flex-1 space-y-0.5 overflow-y-auto px-2 pb-3"
      >
        <button
          :for={{dom_id, item} <- @streams.records}
          id={dom_id}
          type="button"
          phx-click="select"
          phx-value-index={item.index}
          aria-current={item.selected? && "true"}
          class={[
            "group flex w-full items-center gap-3 rounded-lg px-2 py-1.5 text-left transition",
            if(item.selected?,
              do: "bg-sky-500/10 ring-1 ring-sky-400/25",
              else: "hover:bg-white/[0.04]"
            )
          ]}
        >
          <span class={[
            "grid h-7 w-9 shrink-0 place-items-center rounded-md font-mono text-xs font-semibold",
            type_color(item.type)
          ]}>
            {item.type}
          </span>
          <span class="min-w-0 flex-1">
            <span class="flex items-baseline gap-1.5">
              <span class={[
                "truncate text-[13px] font-medium",
                if(item.selected?, do: "text-sky-100", else: "text-zinc-200")
              ]}>
                {item.title}
              </span>
              <span :if={item.idc} class="shrink-0 text-[11px] text-zinc-500">IDC {item.idc}</span>
            </span>
            <span :if={item.subtitle} class="block truncate text-[11px] text-zinc-500">
              {item.subtitle}
            </span>
          </span>
        </button>
      </nav>

      <details :if={@file.warnings != []} id="warnings" class="group border-t border-white/[0.06]">
        <summary class="flex cursor-pointer items-center gap-2 px-4 py-2.5 text-xs text-amber-300/90 select-none hover:bg-white/[0.02]">
          <.icon name="hero-exclamation-circle" class="size-4" />
          {length(@file.warnings)} warning{if length(@file.warnings) != 1, do: "s"}
          <.icon name="hero-chevron-up" class="ml-auto size-3.5 transition group-open:rotate-180" />
        </summary>
        <ul class="max-h-48 space-y-1 overflow-y-auto px-4 pb-3 text-[11px] text-zinc-400">
          <li :for={{offset, reason} <- @file.warnings} class="flex gap-2">
            <span class="shrink-0 font-mono text-zinc-500">@{offset}</span>
            <span>{Viewer.describe(reason)}</span>
          </li>
        </ul>
      </details>
    </aside>
    """
  end

  defp type_color(type) when type in [4, 13, 14, 15], do: "bg-sky-500/15 text-sky-300"
  defp type_color(9), do: "bg-rose-500/15 text-rose-300"
  defp type_color(type) when type in [10, 17], do: "bg-violet-500/15 text-violet-300"
  defp type_color(1), do: "bg-amber-500/15 text-amber-300"
  defp type_color(_), do: "bg-white/[0.06] text-zinc-400"

  # -- Record view -----------------------------------------------------------------

  attr :record, Record
  attr :selected, :integer
  attr :render, :map
  attr :minutiae, :list, required: true
  attr :streams, :any, required: true
  attr :tab, :atom, required: true
  attr :hex, :any
  attr :hex_page, :integer
  attr :hex_pages, :integer

  def record_view(assigns) do
    ~H"""
    <div :if={@record} class="flex min-h-0 flex-1 flex-col">
      <.image_viewer :if={@record.image} record={@record} render={@render} minutiae={@minutiae} />

      <.splitter
        :if={@record.image}
        id="split-fields"
        orientation="horizontal"
        panel="#fields-section"
        side="below"
        var="--fields-h"
        min={120}
        keep={200}
        label="Resize the fields panel"
      />

      <section
        id="fields-section"
        class={[
          "flex min-h-0 flex-col bg-zinc-925",
          if(@record.image, do: "h-(--fields-h) shrink-0", else: "flex-1")
        ]}
      >
        <div class="flex shrink-0 items-center gap-1 border-b border-white/[0.06] px-3">
          <.tab id="tab-fields" active={@tab == :fields} value="fields">
            Fields <span class="ml-1 text-zinc-500">{length(@record.fields)}</span>
          </.tab>
          <.tab id="tab-hex" active={@tab == :hex} value="hex">Hex</.tab>
          <div class="ml-auto flex items-center gap-2 text-[11px] text-zinc-500">
            <span>Type-{@record.type}, {@record.encoding}</span>
            <span class="text-zinc-700">·</span>
            <span title="Offset in the file">
              at <span class="font-mono text-zinc-400">{@record.offset}</span>
            </span>
            <span class="text-zinc-700">·</span>
            <span class="font-mono text-zinc-400">{format_bytes(@record.length)}</span>
          </div>
        </div>

        <%!-- Both panels stay in the DOM so their streams survive switching tabs. --%>
        <div id="fields-panel" class={["min-h-0 flex-1 overflow-auto", @tab != :fields && "hidden"]}>
          <.fields_table streams={@streams} />
        </div>

        <div id="hex-panel" class={["flex min-h-0 flex-1 flex-col", @tab != :hex && "hidden"]}>
          <.hex_view streams={@streams} hex={@hex} page={@hex_page} pages={@hex_pages} />
        </div>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :active, :boolean, required: true
  attr :value, :string, required: true
  slot :inner_block, required: true

  defp tab(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="tab"
      phx-value-tab={@value}
      class={[
        "relative px-3 py-2.5 text-xs font-medium transition",
        if(@active, do: "text-zinc-100", else: "text-zinc-500 hover:text-zinc-300")
      ]}
    >
      {render_slot(@inner_block)}
      <span :if={@active} class="absolute inset-x-2 -bottom-px h-0.5 rounded-full bg-sky-400" />
    </button>
    """
  end

  attr :streams, :any, required: true

  defp fields_table(assigns) do
    ~H"""
    <table class="w-full text-left text-xs">
      <thead class="sticky top-0 z-10 bg-zinc-925/95 backdrop-blur">
        <tr class="text-[11px] tracking-wider text-zinc-500 uppercase">
          <th class="w-24 px-4 py-2 font-semibold">Field</th>
          <th class="w-24 py-2 font-semibold">Name</th>
          <th class="py-2 pr-4 font-semibold">Value</th>
        </tr>
      </thead>
      <tbody id="fields" phx-update="stream" class="divide-y divide-white/[0.04]">
        <tr
          :for={{dom_id, field} <- @streams.fields}
          id={dom_id}
          class="align-top hover:bg-white/[0.02]"
        >
          <td class="px-4 py-1.5 font-mono text-zinc-400">{field.tag}</td>
          <td class="py-1.5 font-medium text-zinc-300">{field.name}</td>
          <td class="py-1.5 pr-4 font-mono text-zinc-200">
            <%= if field.binary? do %>
              <span class="text-zinc-500">Binary data, {format_bytes(field.size)}</span>
              <button
                id={"hex-field-#{field.id}"}
                type="button"
                phx-click="hex_field"
                phx-value-number={field.number}
                class="ml-2 rounded px-1.5 py-0.5 text-[11px] text-sky-300 ring-1 ring-sky-400/30 transition hover:bg-sky-400/10"
              >
                Hex
              </button>
            <% else %>
              <%= if length(field.subfields) > 1 do %>
                <%!-- Repeated subfields: one row each, items in aligned columns --%>
                <div class="max-h-60 overflow-auto">
                  <table class="border-separate border-spacing-0">
                    <tr :for={{items, row} <- Enum.with_index(field.subfields, 1)}>
                      <td class="pr-3 text-right text-zinc-600 tabular-nums select-none">{row}</td>
                      <td
                        :for={item <- items}
                        class={[
                          "border-l border-white/[0.06] px-2 whitespace-nowrap",
                          item == "" && "text-zinc-600"
                        ]}
                      >
                        {printable(item)}
                      </td>
                    </tr>
                  </table>
                </div>
              <% else %>
                <div :for={items <- field.subfields} class="flex flex-wrap gap-x-1.5 break-all">
                  <%= for {item, i} <- Enum.with_index(items) do %>
                    <span :if={i > 0} class="text-zinc-600">│</span>
                    <span class={item == "" && "text-zinc-600"}>{printable(item)}</span>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp printable(""), do: "∅"

  defp printable(item) do
    if String.printable?(item), do: item, else: "#{byte_size(item)} bytes (not text)"
  end

  attr :streams, :any, required: true
  attr :hex, :any, required: true
  attr :page, :integer, required: true
  attr :pages, :integer, required: true

  defp hex_view(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-3 px-4 py-2 text-[11px] text-zinc-500">
      <span id="hex-target">
        <%= case @hex do %>
          <% {:record, _} -> %>
            Whole record (file offsets)
          <% {:field, _, number} -> %>
            Field {number} (offsets within the field)
            <button
              id="hex-back"
              type="button"
              phx-click="hex_record"
              class="ml-2 text-sky-300 hover:underline"
            >
              Show record
            </button>
          <% _ -> %>
        <% end %>
      </span>
      <div :if={@pages > 1} class="ml-auto flex items-center gap-2">
        <button
          id="hex-prev"
          type="button"
          phx-click="hex_page"
          phx-value-page={@page - 1}
          disabled={@page == 0}
          class="rounded p-1 transition hover:bg-white/[0.06] disabled:opacity-30"
        >
          <.icon name="hero-chevron-left" class="size-3.5" />
        </button>
        <span class="tabular-nums">{@page + 1} / {@pages}</span>
        <button
          id="hex-next"
          type="button"
          phx-click="hex_page"
          phx-value-page={@page + 1}
          disabled={@page + 1 >= @pages}
          class="rounded p-1 transition hover:bg-white/[0.06] disabled:opacity-30"
        >
          <.icon name="hero-chevron-right" class="size-3.5" />
        </button>
      </div>
    </div>
    <div class="min-h-0 flex-1 overflow-auto px-4 pb-3">
      <div id="hex-lines" phx-update="stream" class="font-mono text-[11px] leading-5 whitespace-pre">
        <div
          :for={{dom_id, line} <- @streams.hex}
          id={dom_id}
          class="flex gap-6 hover:bg-white/[0.03]"
        >
          <span class="text-zinc-600 tabular-nums">{offset_label(line.offset)}</span>
          <span class="w-[25rem] text-zinc-300">{line.hex}</span>
          <span class="text-zinc-500">{line.ascii}</span>
        </div>
      </div>
    </div>
    """
  end

  defp offset_label(offset), do: offset |> Integer.to_string(16) |> String.pad_leading(8, "0")

  @doc "A byte count for people: `812 bytes`, `14.2 KB`, `3.1 MB`."
  def format_bytes(n) when n < 1000, do: "#{n} bytes"
  def format_bytes(n) when n < 1_000_000, do: "#{Float.round(n / 1000, 1)} KB"
  def format_bytes(n), do: "#{Float.round(n / 1_000_000, 1)} MB"

  # -- Splitter ----------------------------------------------------------------------

  @doc """
  A handle that resizes a panel by setting a CSS variable on the document
  element, which the panel's size is written in. Drag it, use the arrow keys
  when it has focus, or double-click it to go back to the default size.

  The size lasts as long as the window, across files. It is not stored:
  browser storage is written to disk, and the app writes nothing there.
  """
  attr :id, :string, required: true
  attr :orientation, :string, required: true, values: ["vertical", "horizontal"]
  attr :panel, :string, required: true, doc: "selector of the panel being sized"
  attr :side, :string, required: true, values: ["left", "below"]
  attr :var, :string, required: true
  attr :min, :integer, required: true
  attr :keep, :integer, required: true, doc: "space to leave for the other side"
  attr :label, :string, required: true

  def splitter(assigns) do
    ~H"""
    <div
      id={@id}
      role="separator"
      tabindex="0"
      aria-orientation={@orientation}
      aria-label={@label}
      title={@label}
      phx-hook=".Splitter"
      data-panel={@panel}
      data-side={@side}
      data-var={@var}
      data-min={@min}
      data-keep={@keep}
      class={[
        "group relative z-20 shrink-0 bg-white/[0.06] outline-none",
        if(@orientation == "vertical",
          do: "w-px cursor-col-resize",
          else: "h-px cursor-row-resize"
        )
      ]}
    >
      <%!-- A wider, invisible grip; the line lights up on hover and focus. --%>
      <span class={[
        "absolute transition-colors group-hover:bg-sky-400/50 group-focus-visible:bg-sky-400/70 group-active:bg-sky-400/70",
        if(@orientation == "vertical",
          do: "inset-y-0 -left-[2px] w-[5px]",
          else: "inset-x-0 -top-[2px] h-[5px]"
        )
      ]} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Splitter">
      export default {
        mounted() {
          this.scope = document.documentElement
          const {panel, side, var: name, min, keep} = this.el.dataset
          this.opts = {panel, vertical: side === "left", name, min: +min, keep: +keep}

          this.el.addEventListener("pointerdown", e => this.start(e))
          this.el.addEventListener("dblclick", () => this.reset())
          this.el.addEventListener("keydown", e => this.key(e))
        },

        panel() { return document.querySelector(this.opts.panel) },

        size() {
          const rect = this.panel().getBoundingClientRect()
          return this.opts.vertical ? rect.width : rect.height
        },

        set(px) {
          const parent = this.panel().parentElement.getBoundingClientRect()
          const room = (this.opts.vertical ? parent.width : parent.height) - this.opts.keep
          const value = `${Math.round(Math.max(this.opts.min, Math.min(px, room)))}px`
          this.scope.style.setProperty(this.opts.name, value)
        },

        start(e) {
          if (e.button !== 0) return
          e.preventDefault()
          const rect = this.panel().getBoundingClientRect()
          const move = ev => this.set(this.opts.vertical ? ev.clientX - rect.left : rect.bottom - ev.clientY)
          const stop = () => {
            window.removeEventListener("pointermove", move)
            document.body.classList.remove("select-none", this.opts.vertical ? "cursor-col-resize" : "cursor-row-resize")
          }
          document.body.classList.add("select-none", this.opts.vertical ? "cursor-col-resize" : "cursor-row-resize")
          window.addEventListener("pointermove", move)
          window.addEventListener("pointerup", stop, {once: true})
        },

        key(e) {
          const grow = this.opts.vertical ? "ArrowRight" : "ArrowUp"
          const shrink = this.opts.vertical ? "ArrowLeft" : "ArrowDown"
          if (e.key !== grow && e.key !== shrink) return
          e.preventDefault()
          e.stopPropagation()
          const step = e.shiftKey ? 64 : 16
          this.set(this.size() + (e.key === grow ? step : -step))
        },

        reset() {
          this.scope.style.removeProperty(this.opts.name)
        },
      }
    </script>
    """
  end

  # -- Image viewer ----------------------------------------------------------------

  attr :record, Record, required: true
  attr :render, :map
  attr :minutiae, :list, required: true

  def image_viewer(assigns) do
    assigns =
      assign(assigns,
        image: assigns.record.image,
        counts: minutiae_counts(assigns.minutiae)
      )

    ~H"""
    <div
      id="viewer"
      phx-hook=".ImageViewer"
      data-ppi={@image.ppi}
      class="flex min-h-0 flex-1 flex-col"
    >
      <%!-- Title and tools, above the image rather than over it --%>
      <div class="relative z-10 flex h-10 shrink-0 items-center gap-3 border-b border-white/[0.06] bg-zinc-925 pr-2 pl-4">
        <p id="viewer-title" class="min-w-0 truncate text-xs text-zinc-400">
          <span class="font-medium text-zinc-100">{Viewer.title(@record)}</span>
          <span class="px-1 text-zinc-700">·</span>{Viewer.image_summary(@record)}
        </p>

        <%!-- State lives in the hook --%>
        <div
          id="viewer-toolbar"
          phx-update="ignore"
          class="ml-auto flex shrink-0 items-center gap-0.5"
        >
          <.tool action="zoom-out" title="Zoom out (−)" icon="hero-minus" />
          <span
            data-zoom-label
            class="w-11 text-center font-mono text-[11px] tabular-nums text-zinc-300"
          >
            100%
          </span>
          <.tool action="zoom-in" title="Zoom in (+)" icon="hero-plus" />
          <div class="mx-1.5 h-4 w-px bg-white/[0.08]" />
          <.tool action="fit" title="Fit (F)" label="Fit" />
          <.tool action="zoom-1" title="Actual pixels (1)" label="1:1" />
          <.tool action="zoom-2" title="2× (2)" label="2:1" />
          <div class="mx-1.5 h-4 w-px bg-white/[0.08]" />
          <.tool action="invert" title="Invert (I)" label="Invert" toggle />
          <div class="relative">
            <.tool
              action="adjust"
              title="Contrast, brightness and gamma"
              icon="hero-adjustments-horizontal"
            />
            <div
              data-adjust-panel
              class="absolute top-full right-0 mt-2 hidden w-60 space-y-3 rounded-xl bg-zinc-900 p-3.5 shadow-2xl ring-1 shadow-black/60 ring-white/10"
            >
              <p class="text-[11px] font-semibold tracking-wider text-zinc-500 uppercase">
                Adjust display
              </p>
              <.slider name="contrast" label="Contrast" min="0.2" max="3" value="1" />
              <.slider name="brightness" label="Brightness" min="0.2" max="3" value="1" />
              <.slider name="gamma" label="Gamma" min="0.2" max="3" value="1" />
              <button
                data-action="reset"
                type="button"
                class="w-full rounded-md py-1.5 text-[11px] text-zinc-400 ring-1 ring-white/10 transition hover:bg-white/[0.06] hover:text-zinc-200"
              >
                Reset (R)
              </button>
            </div>
          </div>
          <svg width="0" height="0" class="absolute">
            <filter id="viewer-gamma" color-interpolation-filters="sRGB">
              <feComponentTransfer>
                <feFuncR type="gamma" amplitude="1" exponent="1" offset="0" />
                <feFuncG type="gamma" amplitude="1" exponent="1" offset="0" />
                <feFuncB type="gamma" amplitude="1" exponent="1" offset="0" />
              </feComponentTransfer>
            </filter>
          </svg>
        </div>
      </div>

      <div
        id="viewer-viewport"
        data-viewport
        class="viewer-canvas relative min-h-0 flex-1 cursor-grab touch-none overflow-hidden select-none active:cursor-grabbing"
      >
        <%= case @render do %>
          <% %{status: :ok, url: url} = render -> %>
            <%!-- The hook puts the image in #viewer-picture and keeps recent
                 ones loaded (data-key names the file and record). A large
                 JPEG 2000 image also has a smaller preview (data-preview, or
                 data-src itself until the full image is decoded), which is
                 shown while the full one loads; data-width and data-height
                 give the full size, which the stage always has. --%>
            <div
              id="viewer-stage"
              data-stage
              data-src={url}
              data-preview={render[:preview]}
              data-key={render[:key]}
              data-width={render[:width]}
              data-height={render[:height]}
              data-alt={Viewer.title(@record)}
              phx-mounted={JS.ignore_attributes(["style"])}
              class="absolute top-0 left-0 origin-top-left shadow-[0_0_0_1px_rgba(255,255,255,0.06),0_12px_40px_rgba(0,0,0,0.6)]"
            >
              <div
                id="viewer-filter"
                data-filter
                phx-mounted={JS.ignore_attributes(["style"])}
                class="h-full w-full"
              >
                <div id="viewer-picture" data-picture phx-update="ignore" class="h-full w-full"></div>
              </div>
              <.minutiae_overlay
                :if={@minutiae != []}
                sets={@minutiae}
                width={@image.width}
                height={@image.height}
              />
            </div>
          <% %{status: :error, error: error} -> %>
            <div id="viewer-error" class="grid h-full place-items-center">
              <div class="max-w-sm text-center">
                <div class="mx-auto grid size-12 place-items-center rounded-xl bg-rose-500/10 ring-1 ring-rose-400/20">
                  <.icon name="hero-photo" class="size-6 text-rose-300/80" />
                </div>
                <p class="mt-3 text-sm font-medium text-zinc-200">This image can't be shown</p>
                <p class="mt-1 text-xs text-zinc-500">{error}</p>
              </div>
            </div>
          <% _ -> %>
            <div id="viewer-loading" class="grid h-full place-items-center">
              <div class="flex items-center gap-2 text-xs text-zinc-500">
                <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" /> Decoding…
              </div>
            </div>
        <% end %>
      </div>

      <%!-- Minutiae legend and the pixel under the cursor, below the image --%>
      <div class="flex h-8 shrink-0 items-center gap-3 border-t border-white/[0.06] bg-zinc-925 px-2 text-[11px]">
        <%= if @minutiae != [] do %>
          <button
            id="toggle-minutiae"
            type="button"
            data-toggle-minutiae
            aria-pressed="true"
            phx-click={
              JS.toggle_class("hidden", to: "#minutiae-overlay")
              |> JS.toggle_attribute({"aria-pressed", "true", "false"})
            }
            class="flex items-center gap-1.5 rounded-md px-2 py-0.5 font-medium text-zinc-400 transition hover:text-zinc-100 aria-pressed:bg-white/[0.06] aria-pressed:text-zinc-100"
            title="Show minutiae (M)"
          >
            <.icon name="hero-eye" class="size-3.5" /> Minutiae
          </button>
          <span class="flex min-w-0 items-center gap-3 truncate text-zinc-400">
            <.legend label="Ending" count={@counts.ridge_ending} class="rounded-full bg-rose-400" />
            <.legend label="Bifurcation" count={@counts.bifurcation} class="rounded-sm bg-cyan-400" />
            <.legend
              :if={@counts.other > 0}
              label="Other"
              count={@counts.other}
              class="rounded-full bg-amber-300"
            />
            <.legend
              :if={@counts.cores > 0}
              label="Core"
              count={@counts.cores}
              class="rounded-full ring-2 ring-yellow-300"
            />
            <.legend
              :if={@counts.deltas > 0}
              label="Delta"
              count={@counts.deltas}
              class="bg-lime-300 [clip-path:polygon(50%_0,100%_100%,0_100%)]"
            />
          </span>
        <% end %>

        <div
          id="viewer-readout"
          phx-update="ignore"
          data-hint="Scroll to zoom · drag to pan · double-click to fit"
          class="ml-auto shrink-0 truncate pr-2 text-zinc-500 tabular-nums"
        >
          Scroll to zoom · drag to pan · double-click to fit
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ImageViewer">
        // Loaded images by data-key (file and record): the latest of preview
        // and full image, with the image's full size. Kept across mounts, so
        // going back to a record shows it at once. In memory only.
        const cache = new Map()
        const CACHE_SIZE = 8

        function remember(key, entry) {
          cache.delete(key)
          cache.set(key, entry)
          while (cache.size > CACHE_SIZE) cache.delete(cache.keys().next().value)
        }

        export default {
          mounted() {
            this.state = {scale: 1, tx: 0, ty: 0, invert: false, contrast: 1, brightness: 1, gamma: 1, fitMode: true}
            this.viewport = this.el.querySelector("[data-viewport]")
            this.readout = this.el.querySelector("#viewer-readout")
            this.panel = this.el.querySelector("[data-adjust-panel]")
            this.zoomLabel = this.el.querySelector("[data-zoom-label]")
            this.listeners = []
            this.loading = new Set()
            this.pixels = null

            this.on(this.el, "click", e => this.onClick(e))
            this.on(this.el, "input", e => this.onInput(e))
            this.on(this.viewport, "wheel", e => this.onWheel(e), {passive: false})
            this.on(this.viewport, "pointerdown", e => this.onPointerDown(e))
            this.on(this.viewport, "pointermove", e => this.onPointerMove(e))
            this.on(this.viewport, "pointerup", e => this.onPointerUp(e))
            this.on(this.viewport, "pointerleave", () => this.setReadout(""))
            this.on(this.viewport, "dblclick", () => this.fit())
            this.on(window, "keydown", e => this.onKey(e))
            this.on(document, "pointerdown", e => {
              if (!e.target.closest("[data-adjust-panel], [data-action=adjust]")) this.panel.classList.add("hidden")
            })

            this.resizer = new ResizeObserver(() => this.state.fitMode ? this.fit() : this.apply())
            this.resizer.observe(this.viewport)
            this.loadImage()
          },

          updated() { this.loadImage() },

          destroyed() {
            this.listeners.forEach(([target, type, fn, opts]) => target.removeEventListener(type, fn, opts))
            this.resizer.disconnect()
          },

          on(target, type, fn, opts) {
            target.addEventListener(type, fn, opts)
            this.listeners.push([target, type, fn, opts])
          },

          image() { return this.shown?.img },

          stage() { return this.el.querySelector("[data-stage]") },

          // Shows the stage's image: at once if a version of it is loaded,
          // and the newer version (the full image after a preview) when it
          // has loaded. Never another record's image in the meantime.
          loadImage() {
            const stage = this.stage()
            if (!stage) { this.shown = null; return }
            const {src, preview, key} = stage.dataset
            const cached = cache.get(key)

            if (cached) this.show(stage, key, cached)
            else if (this.shown?.key !== key) { stage.querySelector("[data-picture]").replaceChildren(); this.shown = null }

            if (cached?.url !== src) {
              if (preview && !cached) this.fetch(stage, key, preview)
              this.fetch(stage, key, src)
            }
            this.apply()
          },

          fetch(stage, key, src) {
            if (this.loading.has(src)) return
            this.loading.add(src)
            const {width, height} = stage.dataset
            const img = new Image()
            img.src = src
            img.decode().catch(() => {}).then(() => {
              this.loading.delete(src)
              if (!img.naturalWidth) return
              // The full size, which a preview is smaller than.
              const size = [parseInt(width) || img.naturalWidth, parseInt(height) || img.naturalHeight]
              const entry = {url: src, img, size, full: img.naturalWidth >= size[0]}
              // A preview that loads after its full image is not needed.
              if (cache.get(key)?.full && !entry.full) return
              remember(key, entry)
              const now = this.stage()
              if (now?.dataset.key === key && (entry.full || this.shown?.key !== key || !this.shown.full))
                this.show(now, key, entry)
            })
          },

          show(stage, key, entry) {
            const picture = stage.querySelector("[data-picture]")
            const img = entry.img
            if (this.shown?.img === img && picture.firstChild === img) return

            img.id = "viewer-image"
            img.alt = stage.dataset.alt || ""
            img.draggable = false
            img.className = "block h-full w-full max-w-none"
            picture.replaceChildren(img)

            const newRecord = this.shown?.key !== key
            this.shown = {key, img, size: entry.size, full: entry.full}
            this.pixels = null
            newRecord ? this.fit() : this.apply()
          },

          // A copy of the pixels for the readout, made when first needed and
          // only for images that are not huge.
          readPixels() {
            const img = this.image()
            if (!img || this.pixels !== null) return this.pixels
            const w = img.naturalWidth, h = img.naturalHeight
            this.pixels = false
            if (w * h > 40e6) return this.pixels
            try {
              const canvas = document.createElement("canvas")
              canvas.width = w
              canvas.height = h
              const ctx = canvas.getContext("2d", {willReadFrequently: true})
              ctx.drawImage(img, 0, 0)
              this.pixels = ctx
            } catch (_e) { this.pixels = false }
            return this.pixels
          },

          // The image's full size, also while a smaller preview is shown.
          size() {
            if (this.shown) return this.shown.size
            const {width, height} = this.stage()?.dataset || {}
            return width && height ? [parseInt(width), parseInt(height)] : [0, 0]
          },

          fit() {
            const [w, h] = this.size()
            if (!w || !h) return
            const vw = this.viewport.clientWidth, vh = this.viewport.clientHeight
            if (!vw || !vh) return
            const scale = Math.min(vw / w, vh / h) * 0.92
            this.state = {...this.state, scale, tx: (vw - w * scale) / 2, ty: (vh - h * scale) / 2, fitMode: true}
            this.apply()
          },

          zoomTo(scale, cx, cy) {
            const s = this.state
            scale = Math.min(Math.max(scale, 0.02), 32)
            if (cx === undefined) { cx = this.viewport.clientWidth / 2; cy = this.viewport.clientHeight / 2 }
            const k = scale / s.scale
            this.state = {...s, scale, tx: cx - (cx - s.tx) * k, ty: cy - (cy - s.ty) * k, fitMode: false}
            this.apply()
          },

          apply() {
            const stage = this.el.querySelector("[data-stage]")
            const filter = this.el.querySelector("[data-filter]")
            const img = this.image()
            const s = this.state
            const [w, h] = this.size()

            if (stage && w) {
              stage.style.width = `${w}px`
              stage.style.height = `${h}px`
              stage.style.transform = `translate(${s.tx}px, ${s.ty}px) scale(${s.scale})`
            }
            if (img) img.style.imageRendering = s.scale >= 2 ? "pixelated" : "auto"
            if (filter) {
              const gamma = s.gamma !== 1 ? "url(#viewer-gamma) " : ""
              filter.style.filter = `${gamma}invert(${s.invert ? 1 : 0}) contrast(${s.contrast}) brightness(${s.brightness})`
            }
            this.el.querySelectorAll("#viewer-gamma feComponentTransfer > *").forEach(f => f.setAttribute("exponent", 1 / s.gamma))
            this.zoomLabel.textContent = `${Math.round(s.scale * 100)}%`
            this.el.querySelector('[data-action="invert"]')?.setAttribute("aria-pressed", s.invert)
            this.el.querySelectorAll("#minutiae-overlay").forEach(o => o.style.setProperty("--k", 1 / s.scale))
          },

          onClick(e) {
            const button = e.target.closest("[data-action]")
            if (!button) return
            const action = button.dataset.action
            const s = this.state
            if (action === "fit") this.fit()
            else if (action === "zoom-1") this.zoomTo(1)
            else if (action === "zoom-2") this.zoomTo(2)
            else if (action === "zoom-in") this.zoomTo(s.scale * 1.25)
            else if (action === "zoom-out") this.zoomTo(s.scale / 1.25)
            else if (action === "invert") { s.invert = !s.invert; this.apply() }
            else if (action === "adjust") this.panel.classList.toggle("hidden")
            else if (action === "reset") this.resetAdjustments()
          },

          onInput(e) {
            const name = e.target.dataset.control
            if (!name) return
            this.state[name] = parseFloat(e.target.value)
            this.el.querySelector(`[data-value="${name}"]`).textContent = this.state[name].toFixed(2)
            this.apply()
          },

          resetAdjustments() {
            for (const name of ["contrast", "brightness", "gamma"]) {
              this.state[name] = 1
              const input = this.el.querySelector(`[data-control="${name}"]`)
              input.value = 1
              this.el.querySelector(`[data-value="${name}"]`).textContent = "1.00"
            }
            this.state.invert = false
            this.apply()
          },

          onWheel(e) {
            e.preventDefault()
            const rect = this.viewport.getBoundingClientRect()
            this.zoomTo(this.state.scale * Math.exp(-e.deltaY * 0.0015), e.clientX - rect.left, e.clientY - rect.top)
          },

          onPointerDown(e) {
            if (e.button !== 0) return
            this.drag = {x: e.clientX, y: e.clientY}
            this.viewport.setPointerCapture(e.pointerId)
          },

          onPointerMove(e) {
            if (this.drag) {
              this.state.tx += e.clientX - this.drag.x
              this.state.ty += e.clientY - this.drag.y
              this.state.fitMode = false
              this.drag = {x: e.clientX, y: e.clientY}
              this.apply()
            }
            this.updateReadout(e)
          },

          onPointerUp(e) {
            this.drag = null
            if (this.viewport.hasPointerCapture(e.pointerId)) this.viewport.releasePointerCapture(e.pointerId)
          },

          updateReadout(e) {
            const [w, h] = this.size()
            const rect = this.viewport.getBoundingClientRect()
            const x = Math.floor((e.clientX - rect.left - this.state.tx) / this.state.scale)
            const y = Math.floor((e.clientY - rect.top - this.state.ty) / this.state.scale)
            if (!w || x < 0 || y < 0 || x >= w || y >= h) { this.setReadout(""); return }

            let text = `x ${x}  y ${y}`
            const ppi = parseFloat(this.el.dataset.ppi)
            if (ppi > 0) text += `   ${(x / ppi * 25.4).toFixed(2)}, ${(y / ppi * 25.4).toFixed(2)} mm`
            const pixels = this.readPixels()
            if (pixels) {
              // A preview has fewer pixels than the image.
              const img = this.image()
              const px = Math.floor(x * img.naturalWidth / w), py = Math.floor(y * img.naturalHeight / h)
              const [r, g, b] = pixels.getImageData(px, py, 1, 1).data
              text += r === g && g === b ? `   value ${r}` : `   rgb ${r} ${g} ${b}`
            }
            this.setReadout(text)
          },

          // With no pixel under the cursor, shows how to move around instead.
          setReadout(text) {
            this.readout.textContent = text || this.readout.dataset.hint
            this.readout.classList.toggle("text-zinc-300", text !== "")
            this.readout.classList.toggle("font-mono", text !== "")
            this.readout.classList.toggle("text-zinc-500", text === "")
          },

          onKey(e) {
            if (e.metaKey || e.ctrlKey || e.altKey) return
            if (["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName)) return
            const s = this.state
            const actions = {
              f: () => this.fit(), "1": () => this.zoomTo(1), "2": () => this.zoomTo(2),
              "+": () => this.zoomTo(s.scale * 1.25), "=": () => this.zoomTo(s.scale * 1.25),
              "-": () => this.zoomTo(s.scale / 1.25),
              i: () => { s.invert = !s.invert; this.apply() },
              r: () => this.resetAdjustments(),
              Escape: () => this.panel.classList.add("hidden"),
              m: () => this.el.querySelector("[data-toggle-minutiae]")?.click(),
            }
            const action = actions[e.key]
            if (action) { e.preventDefault(); action() }
          },
        }
      </script>
    </div>
    """
  end

  attr :action, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :label, :string, default: nil
  attr :toggle, :boolean, default: false

  defp tool(assigns) do
    ~H"""
    <button
      type="button"
      data-action={@action}
      title={@title}
      aria-pressed={@toggle && "false"}
      aria-label={@title}
      class="grid h-7 min-w-7 place-items-center rounded-md px-1.5 text-[11px] font-medium text-zinc-400 transition hover:bg-white/[0.08] hover:text-zinc-100 aria-pressed:bg-sky-500/20 aria-pressed:text-sky-200"
    >
      <.icon :if={@icon} name={@icon} class="size-4" />
      <span :if={@label}>{@label}</span>
    </button>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :class, :string, required: true

  defp legend(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <span class={["size-2 shrink-0", @class]} />
      {@label} <span class="font-mono text-zinc-200 tabular-nums">{@count}</span>
    </span>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :min, :string, required: true
  attr :max, :string, required: true
  attr :value, :string, required: true

  defp slider(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1 flex justify-between text-[11px] text-zinc-400">
        {@label} <span data-value={@name} class="font-mono tabular-nums text-zinc-300">1.00</span>
      </span>
      <input
        type="range"
        data-control={@name}
        min={@min}
        max={@max}
        step="0.01"
        value={@value}
        class="h-1 w-full cursor-pointer appearance-none rounded-full bg-white/10 accent-sky-400"
      />
    </label>
    """
  end

  # -- Minutiae overlay --------------------------------------------------------------

  attr :sets, :list, required: true
  attr :width, :integer, required: true
  attr :height, :integer, required: true

  defp minutiae_overlay(assigns) do
    ~H"""
    <svg
      id="minutiae-overlay"
      viewBox={"0 0 #{@width} #{@height}"}
      preserveAspectRatio="none"
      class="pointer-events-none absolute inset-0 h-full w-full"
      style="--k: 1"
    >
      <%= for set <- @sets do %>
        <g :for={m <- set.minutiae} class={minutia_class(m.type)}>
          <%= if m.type == :bifurcation do %>
            <rect
              x={m.x - 4}
              y={m.y - 4}
              width="8"
              height="8"
              fill="none"
              stroke-width="1.5"
              vector-effect="non-scaling-stroke"
            />
          <% else %>
            <circle
              cx={m.x}
              cy={m.y}
              r="4.5"
              fill="none"
              stroke-width="1.5"
              vector-effect="non-scaling-stroke"
            />
          <% end %>
          <line
            :if={m.angle}
            x1={m.x}
            y1={m.y}
            x2={m.x + 14 * :math.cos(m.angle * :math.pi() / 180)}
            y2={m.y - 14 * :math.sin(m.angle * :math.pi() / 180)}
            stroke-width="1.5"
            vector-effect="non-scaling-stroke"
          />
        </g>
        <circle
          :for={c <- set.cores}
          cx={c.x}
          cy={c.y}
          r="9"
          fill="none"
          class="stroke-yellow-300"
          stroke-width="2"
          vector-effect="non-scaling-stroke"
        />
        <path
          :for={d <- set.deltas}
          d={"M #{d.x} #{d.y - 9} L #{d.x + 8} #{d.y + 6} L #{d.x - 8} #{d.y + 6} Z"}
          fill="none"
          class="stroke-lime-300"
          stroke-width="2"
          vector-effect="non-scaling-stroke"
        />
      <% end %>
    </svg>
    """
  end

  defp minutia_class(:ridge_ending), do: "stroke-rose-400"
  defp minutia_class(:bifurcation), do: "stroke-cyan-400"
  defp minutia_class(_), do: "stroke-amber-300"

  defp minutiae_counts(sets) do
    minutiae = Enum.flat_map(sets, & &1.minutiae)
    counts = Enum.frequencies_by(minutiae, &(&1.type || :other))

    %{
      ridge_ending: Map.get(counts, :ridge_ending, 0),
      bifurcation: Map.get(counts, :bifurcation, 0),
      other: Map.get(counts, :other, 0),
      cores: Enum.sum_by(sets, &length(&1.cores)),
      deltas: Enum.sum_by(sets, &length(&1.deltas))
    }
  end

  # -- Tenprint ------------------------------------------------------------------------

  attr :file, NistFile, required: true
  attr :tenprint, :map, required: true
  attr :renders, :map, required: true

  def tenprint_card(assigns) do
    ~H"""
    <div id="tenprint" class="min-h-0 flex-1 overflow-auto p-6">
      <div class="mx-auto max-w-6xl space-y-5">
        <.tenprint_row
          label="Right hand"
          positions={1..5}
          file={@file}
          tenprint={@tenprint}
          renders={@renders}
        />
        <.tenprint_row
          label="Left hand"
          positions={6..10}
          file={@file}
          tenprint={@tenprint}
          renders={@renders}
        />
        <div>
          <h3 class="mb-2 text-[11px] font-semibold tracking-wider text-zinc-500 uppercase">
            Plain impressions
          </h3>
          <div class="grid grid-cols-[2fr_1fr_1fr_2fr] gap-3">
            <.finger_cell
              :for={p <- [14, 12, 11, 13]}
              position={p}
              file={@file}
              tenprint={@tenprint}
              renders={@renders}
              tall
            />
          </div>
          <div :if={@tenprint[15]} class="mt-3 grid grid-cols-3 gap-3">
            <.finger_cell position={15} file={@file} tenprint={@tenprint} renders={@renders} tall />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :positions, :any, required: true
  attr :file, NistFile, required: true
  attr :tenprint, :map, required: true
  attr :renders, :map, required: true

  defp tenprint_row(assigns) do
    ~H"""
    <div>
      <h3 class="mb-2 text-[11px] font-semibold tracking-wider text-zinc-500 uppercase">{@label}</h3>
      <div class="grid grid-cols-5 gap-3">
        <.finger_cell
          :for={p <- @positions}
          position={p}
          file={@file}
          tenprint={@tenprint}
          renders={@renders}
        />
      </div>
    </div>
    """
  end

  attr :position, :integer, required: true
  attr :file, NistFile, required: true
  attr :tenprint, :map, required: true
  attr :renders, :map, required: true
  attr :tall, :boolean, default: false

  defp finger_cell(assigns) do
    index = assigns.tenprint[assigns.position]

    assigns =
      assign(assigns,
        index: index,
        record: index && Enum.at(assigns.file.records, index),
        render: index && assigns.renders[index]
      )

    ~H"""
    <%= if @index do %>
      <button
        id={"finger-#{@position}"}
        type="button"
        phx-click="select"
        phx-value-index={@index}
        title={"Open #{Positions.name(@position)}"}
        class="group overflow-hidden rounded-xl bg-zinc-925 text-left ring-1 ring-white/[0.06] transition hover:ring-sky-400/40 hover:shadow-xl hover:shadow-black/40"
      >
        <div class={[
          "relative grid place-items-center overflow-hidden bg-black",
          if(@tall, do: "h-56", else: "h-44")
        ]}>
          <%= case @render do %>
            <% %{status: :ok, url: url} -> %>
              <img
                src={url}
                alt={Positions.name(@position)}
                class="absolute inset-0 h-full w-full object-contain transition duration-300 group-hover:scale-[1.03]"
              />
            <% %{status: :error} -> %>
              <.icon name="hero-photo" class="size-6 text-zinc-700" />
            <% _ -> %>
              <.icon name="hero-arrow-path" class="size-4 text-zinc-600 motion-safe:animate-spin" />
          <% end %>
        </div>
        <div class="flex items-start gap-2 border-t border-white/[0.06] px-3 py-2">
          <div class="min-w-0 flex-1">
            <p class="truncate text-xs font-medium text-zinc-200">{Positions.name(@position)}</p>
            <p class="truncate text-[11px] text-zinc-500">
              Type-{@record.type} · IDC {@record.idc}
            </p>
          </div>
          <span class="shrink-0 rounded bg-white/[0.05] px-1.5 py-0.5 font-mono text-[10px] text-zinc-400">
            {@position}
          </span>
        </div>
      </button>
    <% else %>
      <div
        id={"finger-#{@position}"}
        class={[
          "grid place-items-center rounded-xl border border-dashed border-white/[0.06] text-center",
          if(@tall, do: "h-[17.5rem]", else: "h-[14.5rem]")
        ]}
      >
        <div>
          <p class="text-xs text-zinc-600">{Positions.name(@position)}</p>
          <p class="text-[11px] text-zinc-700">Not in file</p>
        </div>
      </div>
    <% end %>
    """
  end
end
