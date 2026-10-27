#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::fs;
use std::path::{Component, Path, PathBuf};
use tauri::{AppHandle, Manager};

const TOKENS: &str = include_str!("../../../shared/tokens.json");
const STORE_DIRECTORY: &str = "notes";
const NOTEBOOKS_DIRECTORY: &str = "notebooks";

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
fn load_files(app: AppHandle) -> Result<Vec<StoredFile>, String> {
    let root = store_root(&app)?;
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
    let is_inside_notebooks = relative.starts_with(NOTEBOOKS_DIRECTORY);
    let is_json = relative.extension().is_some_and(|extension| extension == "json");
    if is_plain && is_inside_notebooks && is_json {
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
        .invoke_handler(tauri::generate_handler![tokens, load_files, write_file])
        .run(tauri::generate_context!())
        .expect("the Notes window could not start");
}
