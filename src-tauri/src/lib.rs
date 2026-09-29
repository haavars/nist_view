//! The desktop shell: starts the Elixir side, opens viewer windows on it,
//! and routes files the OS asks us to open.
//!
//! The Elixir release (or `mix phx.server` in development) is started with:
//!
//! * `PORT=0`, so Phoenix binds a free loopback port and reports it back as
//!   `ready:<url>` on the `messages` topic.
//! * `NIST_VIEW_LAUNCH_TOKEN`, a random secret each window URL carries once.
//!   Without it the server answers 403, so other local programs and web pages
//!   cannot use it.
//! * `ELIXIRKIT_PUBSUB`, the channel back to this process.
//!
//! A file to open is sent as `<id>\n<path>` on the `open` topic, then a window
//! is opened on `/?open=<id>`; the page claims the path by that id.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use tauri::{AppHandle, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

struct Shell {
    pubsub: elixirkit::PubSub,
    token: String,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    /// The server's URL once it has reported ready.
    base_url: Option<String>,
    /// Files asked for before the server was ready.
    pending: Vec<PathBuf>,
    windows: u32,
}

impl Shell {
    fn ready(&self, app: &AppHandle, base_url: String) {
        let pending = {
            let mut state = self.state.lock().unwrap();
            state.base_url = Some(base_url);
            std::mem::take(&mut state.pending)
        };

        if pending.is_empty() {
            self.new_window(app, None);
        } else {
            pending.into_iter().for_each(|path| self.open(app, path));
        }
    }

    fn open(&self, app: &AppHandle, path: PathBuf) {
        {
            let mut state = self.state.lock().unwrap();
            if state.base_url.is_none() {
                state.pending.push(path);
                return;
            }
        }

        let id = random_hex(16);
        let message = format!("{id}\n{}", path.display());

        if self.pubsub.broadcast("open", message.as_bytes()).is_ok() {
            self.new_window(app, Some(&id));
        }
    }

    fn new_window(&self, app: &AppHandle, open_id: Option<&str>) {
        let (base_url, n) = {
            let mut state = self.state.lock().unwrap();
            state.windows += 1;
            (state.base_url.clone().expect("server ready"), state.windows)
        };

        let mut url = format!("{base_url}/?launch={}", self.token);
        if let Some(id) = open_id {
            url.push_str(&format!("&open={id}"));
        }

        let origin = base_url.clone();

        let result = WebviewWindowBuilder::new(
            app,
            format!("viewer-{n}"),
            WebviewUrl::External(url.parse().expect("valid URL")),
        )
        .title("NIST Viewer")
        .inner_size(1440.0, 900.0)
        .min_inner_size(900.0, 600.0)
        // Let the page receive dropped files as HTML5 drag and drop.
        .disable_drag_drop_handler()
        // Stay on the local server; nothing else may load in the window.
        .on_navigation(move |url| url.as_str().starts_with(&origin))
        .build();

        if let Err(error) = result {
            eprintln!("[nist-viewer] could not open a window: {error}");
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let shell = Arc::new(Shell {
        pubsub: elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen"),
        token: random_hex(32),
        state: Mutex::new(State::default()),
    });

    // Files on the command line: how Windows and Linux pass file associations.
    shell.state.lock().unwrap().pending = file_args(std::env::args_os().skip(1));

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init({
            let shell = shell.clone();
            move |app, argv, _cwd| {
                let paths = file_args(argv.into_iter().skip(1).map(OsString::from));

                if paths.is_empty() {
                    if let Some(window) = app.webview_windows().values().next() {
                        let _ = window.set_focus();
                    }
                } else {
                    paths.into_iter().for_each(|path| shell.open(app, path));
                }
            }
        }))
        .setup({
            let shell = shell.clone();
            move |app| {
                let handle = app.handle().clone();
                let on_message = shell.clone();

                shell.pubsub.subscribe("messages", move |message| {
                    if let Some(url) = std::str::from_utf8(message)
                        .ok()
                        .and_then(|m| m.strip_prefix("ready:"))
                    {
                        on_message.ready(&handle, url.to_string());
                    }
                });

                let handle = app.handle().clone();
                let shell = shell.clone();

                tauri::async_runtime::spawn_blocking(move || {
                    let rel_dir = handle.path().resource_dir().unwrap().join("rel");
                    let mut command = elixir_command(&rel_dir);
                    command.env("ELIXIRKIT_PUBSUB", shell.pubsub.url());
                    command.env("NIST_VIEW_LAUNCH_TOKEN", &shell.token);
                    command.env("PORT", "0");

                    let status = command.status().expect("failed to start Elixir");
                    handle.exit(status.code().unwrap_or(1));
                });

                Ok(())
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building the application");

    app.run(move |app, event| {
        // macOS delivers file associations (and files dropped on the Dock
        // icon) as an event rather than as arguments.
        #[cfg(target_os = "macos")]
        if let RunEvent::Opened { urls } = &event {
            for url in urls {
                if let Ok(path) = url.to_file_path() {
                    shell.open(app, path);
                }
            }
        }

        let _ = (app, event);
    });
}

fn elixir_command(rel_dir: &Path) -> std::process::Command {
    if cfg!(debug_assertions) {
        // `cargo tauri dev`: run the project from source.
        let mut command = elixirkit::mix("phx.server", &[]);
        command.current_dir("..");
        command
    } else {
        let mut command = elixirkit::release(rel_dir, "nist_view");
        command.env("PHX_SERVER", "true");
        command
    }
}

/// Existing files among the arguments. Skips flags, such as the `-psn_...`
/// macOS may pass.
fn file_args(args: impl IntoIterator<Item = OsString>) -> Vec<PathBuf> {
    args.into_iter()
        .filter(|arg| !arg.to_string_lossy().starts_with('-'))
        .map(PathBuf::from)
        .filter(|path| path.is_file())
        .collect()
}

fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).expect("OS random number generator");
    buf.iter().map(|b| format!("{b:02x}")).collect()
}
