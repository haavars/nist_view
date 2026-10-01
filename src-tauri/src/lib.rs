//! The desktop shell: starts the Elixir side, opens viewer windows on it,
//! and routes files the OS asks us to open.
//!
//! The Elixir release (or `mix phx.server` in development) is started with:
//!
//! * `PORT=0`, so Phoenix binds a free loopback port and reports it back as
//!   `ready:<secret> <url>` on the `messages` topic.
//! * `NIST_VIEW_READY_SECRET`, the secret in that message. The PubSub socket
//!   takes the first local process that connects; without the secret, one
//!   that got there before the server could send its own URL, and we would
//!   open a window on it with the launch token in the URL.
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
    ready_secret: String,
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
            if state.base_url.is_some() {
                return;
            }
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
        ready_secret: random_hex(32),
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
                    match ready_url(message, &on_message.ready_secret) {
                        Some(url) => on_message.ready(&handle, url),
                        None => eprintln!("[nist-viewer] ignored a message on `messages`"),
                    }
                });

                let handle = app.handle().clone();
                let shell = shell.clone();

                tauri::async_runtime::spawn_blocking(move || {
                    let rel_dir = handle.path().resource_dir().unwrap().join("rel");
                    let mut command = elixir_command(&rel_dir);
                    command.env("ELIXIRKIT_PUBSUB", shell.pubsub.url());
                    command.env("NIST_VIEW_LAUNCH_TOKEN", &shell.token);
                    command.env("NIST_VIEW_READY_SECRET", &shell.ready_secret);
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

/// The server's URL from `ready:<secret> <url>`, if the secret is ours and
/// the URL is on loopback.
fn ready_url(message: &[u8], secret: &str) -> Option<String> {
    let rest = std::str::from_utf8(message).ok()?.strip_prefix("ready:")?;
    let (given, url) = rest.split_once(' ')?;

    if !constant_time_eq(given.as_bytes(), secret.as_bytes()) {
        return None;
    }

    let port = url.strip_prefix("http://127.0.0.1:")?;
    port.parse::<u16>().ok().filter(|&p| p != 0)?;
    Some(url.to_string())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |acc, (x, y)| acc | (x ^ y)) == 0
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

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "5ec2e7";

    #[test]
    fn ready_url_needs_the_secret() {
        assert_eq!(
            ready_url(b"ready:5ec2e7 http://127.0.0.1:4123", SECRET).as_deref(),
            Some("http://127.0.0.1:4123")
        );
        assert_eq!(ready_url(b"ready:http://127.0.0.1:4123", SECRET), None);
        assert_eq!(
            ready_url(b"ready:5ec2e8 http://127.0.0.1:4123", SECRET),
            None
        );
        assert_eq!(ready_url(b"ready: http://127.0.0.1:4123", SECRET), None);
        assert_eq!(ready_url(b"ready:5ec2e7 http://127.0.0.1:4123", ""), None);
    }

    #[test]
    fn ready_url_must_be_loopback_with_a_port() {
        for url in [
            "http://evil.example:4123",
            "http://127.0.0.1.evil.example:80",
            "http://127.0.0.1:4123/path",
            "http://127.0.0.1:4123@evil.example",
            "http://127.0.0.1:0",
            "http://127.0.0.1:",
            "https://127.0.0.1:4123",
        ] {
            let message = format!("ready:{SECRET} {url}");
            assert_eq!(ready_url(message.as_bytes(), SECRET), None, "{url}");
        }
    }
}
