#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::fs;
use std::path::{Component, Path, PathBuf};
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;

const TOKENS: &str = include_str!("../../../shared/tokens.json");
const BACKGROUND_ART: &str = include_str!("../../../ios/VadosNotes/Resources/background.txt");
const STORE_DIRECTORY: &str = "notes";
const NOTEBOOKS_DIRECTORY: &str = "notebooks";
const SYNCED_DIRECTORY: &str = "synced";
const SYNC_STATE_FILE: &str = "sync-state.json";
const ASSETS_DIRECTORY: &str = "assets";
const ASSET_PATH_HEADER: &str = "asset-path";
const EXPORT_NAME_HEADER: &str = "export-name";
const KEYCHAIN_SERVICE: &str = "com.vaditim.notes.github";
const KEYCHAIN_ACCOUNT: &str = "token";

#[derive(Serialize)]
struct StoredFile {
    path: String,
    contents: String,
}

#[tauri::command]
fn tokens() -> &'static str {
    TOKENS
}

#[tauri::command]
fn background_art() -> &'static str {
    BACKGROUND_ART
}

#[tauri::command]
fn load_files(app: AppHandle, synced: Option<bool>) -> Result<Vec<StoredFile>, String> {
    let store = store_root(&app)?;
    let root = if synced.unwrap_or(false) { store.join(SYNCED_DIRECTORY) } else { store };
    let mut files = Vec::new();
    collect(&root, &root.join(NOTEBOOKS_DIRECTORY), &mut files)?;
    Ok(files)
}

#[tauri::command]
fn write_file(app: AppHandle, path: String, contents: String) -> Result<(), String> {
    let relative = checked_relative_path(&path)?;
    let target = store_root(&app)?.join(relative);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let staging = target.with_extension("json.writing");
    fs::write(&staging, contents).map_err(|error| error.to_string())?;
    fs::rename(&staging, &target).map_err(|error| error.to_string())
}

#[tauri::command]
fn read_sync_state(app: AppHandle) -> Result<Option<String>, String> {
    let path = store_root(&app)?.join(SYNCED_DIRECTORY).join(SYNC_STATE_FILE);
    match fs::read_to_string(path) {
        Ok(contents) => Ok(Some(contents)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

#[tauri::command]
fn read_token() -> Option<String> {
    keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)
        .ok()
        .and_then(|entry| entry.get_password().ok())
        .filter(|token| !token.is_empty())
}

#[tauri::command]
fn save_token(token: String) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT).map_err(|error| error.to_string())?;
    if token.is_empty() {
        return match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error.to_string()),
        };
    }
    entry.set_password(&token).map_err(|error| error.to_string())
}

#[tauri::command]
fn write_asset(app: AppHandle, request: Request<'_>) -> Result<(), String> {
    let InvokeBody::Raw(bytes) = request.body() else {
        return Err("asset body must be raw bytes".into());
    };
    let path = request
        .headers()
        .get(ASSET_PATH_HEADER)
        .and_then(|value| value.to_str().ok())
        .ok_or("asset path missing")?;
    let relative = checked_asset_path(path)?;
    let target = store_root(&app)?.join(relative);
    if target.exists() {
        return Ok(());
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let staging = target.with_extension("writing");
    fs::write(&staging, bytes).map_err(|error| error.to_string())?;
    fs::rename(&staging, &target).map_err(|error| error.to_string())
}

#[tauri::command]
fn read_asset(app: AppHandle, path: String) -> Result<Response, String> {
    let relative = checked_asset_path(&path)?;
    let bytes = fs::read(store_root(&app)?.join(relative)).map_err(|error| error.to_string())?;
    Ok(Response::new(bytes))
}

#[tauri::command]
async fn export_pdf(app: AppHandle, request: Request<'_>) -> Result<Option<String>, String> {
    let InvokeBody::Raw(bytes) = request.body() else {
        return Err("export body must be raw bytes".into());
    };
    let name = request
        .headers()
        .get(EXPORT_NAME_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(percent_decoded)
        .unwrap_or_else(|| "Note.pdf".into());
    let chosen = app
        .dialog()
        .file()
        .set_file_name(&name)
        .add_filter("PDF", &["pdf"])
        .blocking_save_file();
    let Some(chosen) = chosen else {
        return Ok(None);
    };
    let target = chosen.into_path().map_err(|error| error.to_string())?;
    fs::write(&target, bytes).map_err(|error| error.to_string())?;
    Ok(Some(target.to_string_lossy().to_string()))
}

fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let hex = bytes.get(index + 1..index + 3).and_then(|pair| std::str::from_utf8(pair).ok()).and_then(|pair| u8::from_str_radix(pair, 16).ok());
        match (bytes[index], hex) {
            (b'%', Some(value)) => {
                decoded.push(value);
                index += 3;
            }
            (byte, _) => {
                decoded.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&decoded).to_string()
}

fn checked_asset_path(path: &str) -> Result<PathBuf, String> {
    let relative = Path::new(path);
    let mut components = relative.components();
    let is_assets = matches!(components.next(), Some(Component::Normal(first)) if first == ASSETS_DIRECTORY);
    let name = match (components.next(), components.next()) {
        (Some(Component::Normal(name)), None) => name.to_string_lossy().to_string(),
        _ => String::new(),
    };
    let is_hashed_pdf = name.len() == 68 && name.ends_with(".pdf") && name[..64].chars().all(|character| character.is_ascii_hexdigit());
    if is_assets && is_hashed_pdf {
        Ok(relative.to_path_buf())
    } else {
        Err(format!("refused asset path {path}"))
    }
}

fn store_root(app: &AppHandle) -> Result<PathBuf, String> {
    let root = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join(STORE_DIRECTORY);
    fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    Ok(root)
}

fn checked_relative_path(path: &str) -> Result<PathBuf, String> {
    let relative = Path::new(path);
    let is_plain = relative
        .components()
        .all(|component| matches!(component, Component::Normal(_)));
    let is_working = relative.starts_with(NOTEBOOKS_DIRECTORY);
    let is_synced = relative.starts_with(Path::new(SYNCED_DIRECTORY).join(NOTEBOOKS_DIRECTORY));
    let is_state = relative == Path::new(SYNCED_DIRECTORY).join(SYNC_STATE_FILE);
    let is_json = relative.extension().is_some_and(|extension| extension == "json");
    if is_plain && is_json && (is_working || is_synced || is_state) {
        Ok(relative.to_path_buf())
    } else {
        Err(format!("refused path {path}"))
    }
}

fn collect(root: &Path, directory: &Path, files: &mut Vec<StoredFile>) -> Result<(), String> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Ok(());
    };
    for entry in entries {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.is_dir() {
            collect(root, &path, files)?;
        } else if path.extension().is_some_and(|extension| extension == "json") {
            let relative = path.strip_prefix(root).map_err(|error| error.to_string())?;
            let portable = relative
                .components()
                .map(|component| component.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("/");
            let contents = fs::read_to_string(&path).map_err(|error| error.to_string())?;
            files.push(StoredFile {
                path: portable,
                contents,
            });
        }
    }
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            tokens,
            background_art,
            load_files,
            write_file,
            read_sync_state,
            read_token,
            save_token,
            write_asset,
            read_asset,
            export_pdf
        ])
        .run(tauri::generate_context!())
        .expect("the Notes window could not start");
}
