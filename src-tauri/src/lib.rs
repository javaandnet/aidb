mod commands;
mod driver;
mod store;

use commands::AppState;
use std::sync::Arc;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let dir = app.path().app_data_dir().expect("no app data dir");
            std::fs::create_dir_all(&dir).ok();
            let db_path = dir.join("aidb-config.db");
            let st = store::Store::open(&db_path).expect("failed to open config store");
            let state = app.state::<AppState>();
            *state.store.lock().unwrap() = Some(Arc::new(st));
            Ok(())
        })
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::save_connection,
            commands::list_connections,
            commands::delete_connection,
            commands::test_connection,
            commands::connect,
            commands::disconnect,
            commands::get_schema,
            commands::list_columns,
            commands::query_table,
            commands::apply_changes,
            commands::execute_sql,
            commands::apply_ddl,
            commands::get_table_ddl,
            commands::list_history,
            commands::clear_history,
            commands::export_result,
            commands::import_preview,
            commands::import_rows,
            commands::import_csv,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
