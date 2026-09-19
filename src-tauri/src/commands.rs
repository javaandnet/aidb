//! Tauri command 出口：连接管理 / schema / 查询 / 编辑 / 导入导出 / 历史
//! 注意：统一采用"取锁 -> 克隆 Active -> 释放锁"模式，避免 MutexGuard 跨 await。

use crate::driver::{
    mysql::{self, MysqlPool},
    sqlite::SqliteDb,
    ColumnInfo, PageResult, QueryResult, RowChange, TableInfo,
};
use crate::store::{self, ConnectionProfile, HistoryEntry, Store};
use rusqlite::types::Value as SValue;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tauri::State;

#[derive(Clone)]
pub enum Active {
    Sqlite(Arc<SqliteDb>),
    Mysql(MysqlPool),
}

#[derive(Default)]
pub struct AppState {
    pub store: Arc<Mutex<Option<Arc<Store>>>>,
    pub conns: Mutex<HashMap<String, Active>>,
}

fn active_of(state: &AppState, id: &str) -> Result<Active, String> {
    let conns = state.conns.lock().unwrap();
    conns
        .get(id)
        .cloned()
        .ok_or_else(|| "not connected. please connect first.".to_string())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionInput {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub file_path: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub user: Option<String>,
    pub default_db: Option<String>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn get_store(state: &AppState) -> Result<Arc<Store>, String> {
    let guard = state.store.lock().unwrap();
    guard
        .as_ref()
        .cloned()
        .ok_or_else(|| "config store not initialized".into())
}

fn new_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let salt = (std::process::id() as u64) << 32 | (nanos & 0xffff_ffff);
    format!("c_{nanos:x}{salt:x}")
}

fn to_profile(i: &ConnectionInput, old: Option<&ConnectionProfile>) -> ConnectionProfile {
    ConnectionProfile {
        id: if i.id.is_empty() { new_id() } else { i.id.clone() },
        name: i.name.clone(),
        kind: i.kind.clone(),
        file_path: i.file_path.clone(),
        host: i.host.clone(),
        port: i.port,
        user: i.user.clone(),
        default_db: i.default_db.clone(),
        created_at: old.map(|o| o.created_at).unwrap_or_else(now_ms),
        updated_at: now_ms(),
        created_by: old
            .map(|o| o.created_by.clone())
            .unwrap_or_else(|| "local".into()),
        updated_by: "local".into(),
    }
}

// ---------------- 连接管理 ----------------

#[tauri::command]
pub async fn save_connection(
    state: State<'_, AppState>,
    input: ConnectionInput,
    password: Option<String>,
) -> Result<ConnectionProfile, String> {
    let store = get_store(&state)?;
    let old = store
        .list_connections()?
        .into_iter()
        .find(|c| c.id == input.id);
    let profile = to_profile(&input, old.as_ref());
    store.save_connection(&profile)?;
    if let Some(pwd) = password.filter(|p| !p.is_empty()) {
        store::set_password(&profile.id, &pwd)?;
    }
    Ok(profile)
}

#[tauri::command]
pub async fn list_connections(
    state: State<'_, AppState>,
) -> Result<Vec<ConnectionProfile>, String> {
    let store = get_store(&state)?;
    store.list_connections()
}

#[tauri::command]
pub async fn delete_connection(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let store = get_store(&state)?;
    store.delete_connection(&id)?;
    store::delete_password(&id);
    state.conns.lock().unwrap().remove(&id);
    Ok(())
}

async fn open_active(p: &ConnectionProfile, password: Option<String>) -> Result<Active, String> {
    match p.kind.as_str() {
        "sqlite" => {
            let path = p.file_path.clone().unwrap_or_default();
            if path.is_empty() {
                return Err("sqlite file path is empty".into());
            }
            Ok(Active::Sqlite(Arc::new(SqliteDb::open(&path)?)))
        }
        "mysql" => {
            let pwd = password.unwrap_or_default();
            let pool = mysql::build_pool(
                &p.host.clone().unwrap_or_else(|| "127.0.0.1".into()),
                p.port.unwrap_or(3306),
                &p.user.clone().unwrap_or_else(|| "root".into()),
                &pwd,
                p.default_db.as_deref(),
            );
            // 立即验证一次
            mysql::exec_one(&pool, "SELECT 1").await?;
            Ok(Active::Mysql(pool))
        }
        other => Err(format!("unsupported connection kind: {other}")),
    }
}

fn resolve_password(p: &ConnectionProfile, input: Option<String>) -> Option<String> {
    input
        .filter(|s| !s.is_empty())
        .or_else(|| store::get_password(&p.id))
}

#[tauri::command]
pub async fn test_connection(
    state: State<'_, AppState>,
    input: ConnectionInput,
    password: Option<String>,
) -> Result<String, String> {
    let old = get_store(&state)
        .ok()
        .and_then(|s| s.list_connections().ok())
        .and_then(|v| v.into_iter().find(|c| c.id == input.id));
    let profile = to_profile(&input, old.as_ref());
    let pwd = resolve_password(&profile, password);
    let active = open_active(&profile, pwd).await?;
    let version = match &active {
        Active::Sqlite(db) => {
            let r = db.query_all("SELECT sqlite_version()")?;
            mysql::cell_to_string(
                r.rows
                    .first()
                    .and_then(|x| x.first())
                    .unwrap_or(&json!(null)),
            )
        }
        Active::Mysql(pool) => {
            let r = mysql::exec_one(pool, "SELECT VERSION()").await?;
            mysql::cell_to_string(
                r.rows
                    .first()
                    .and_then(|x| x.first())
                    .unwrap_or(&json!(null)),
            )
        }
    };
    Ok(version)
}

#[tauri::command]
pub async fn connect(
    state: State<'_, AppState>,
    id: String,
    password: Option<String>,
) -> Result<(), String> {
    let store = get_store(&state)?;
    let profile = store
        .list_connections()?
        .into_iter()
        .find(|c| c.id == id)
        .ok_or_else(|| "connection profile not found".to_string())?;
    let pwd = resolve_password(&profile, password);
    let active = open_active(&profile, pwd).await?;
    state.conns.lock().unwrap().insert(id, active);
    Ok(())
}

#[tauri::command]
pub async fn disconnect(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.conns.lock().unwrap().remove(&id);
    Ok(())
}

// ---------------- schema ----------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SchemaPayload {
    pub kind: String,
    pub databases: Option<Vec<String>>,
    pub tables: Vec<TableInfo>,
}

#[tauri::command]
pub async fn get_schema(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
) -> Result<SchemaPayload, String> {
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => Ok(SchemaPayload {
            kind: "sqlite".into(),
            databases: None,
            tables: db.list_tables()?,
        }),
        Active::Mysql(pool) => match database {
            None => Ok(SchemaPayload {
                kind: "mysql".into(),
                databases: Some(mysql::list_databases(pool).await?),
                tables: Vec::new(),
            }),
            Some(dbname) => Ok(SchemaPayload {
                kind: "mysql".into(),
                databases: None,
                tables: mysql::list_tables(pool, &dbname).await?,
            }),
        },
    }
}

#[tauri::command]
pub async fn list_columns(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: String,
) -> Result<Vec<ColumnInfo>, String> {
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => db.list_columns(&table),
        Active::Mysql(pool) => {
            let db = database.ok_or_else(|| "database is required for mysql".to_string())?;
            mysql::list_columns(pool, &db, &table).await
        }
    }
}

// ---------------- 数据网格 ----------------

#[tauri::command]
pub async fn query_table(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: String,
    where_sql: Option<String>,
    order_col: Option<String>,
    order_dir: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<PageResult, String> {
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => {
            let db = db.clone();
            let t = table.clone();
            let w = where_sql.clone();
            let oc = order_col.clone();
            let od = order_dir.clone();
            tauri::async_runtime::spawn_blocking(move || {
                db.query_page(&t, w.as_deref(), oc.as_deref(), od.as_deref(), limit, offset)
            })
            .await
            .map_err(|e| e.to_string())?
        }
        Active::Mysql(pool) => {
            let db = database.ok_or_else(|| "database is required for mysql".to_string())?;
            mysql::query_page(
                pool,
                &db,
                &table,
                where_sql.as_deref(),
                order_col.as_deref(),
                order_dir.as_deref(),
                limit,
                offset,
            )
            .await
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangesPayload {
    pub updates: Vec<RowChange>,
    pub inserts: Vec<Vec<(String, serde_json::Value)>>,
    pub deletes: Vec<Vec<(String, serde_json::Value)>>,
}

#[tauri::command]
pub async fn apply_changes(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: String,
    changes: ChangesPayload,
) -> Result<usize, String> {
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => {
            let db = db.clone();
            let t = table.clone();
            let updates = changes.updates;
            let inserts: Vec<Vec<(String, SValue)>> = changes
                .inserts
                .iter()
                .map(|row| {
                    row.iter()
                        .map(|(k, v)| (k.clone(), crate::driver::json_to_sqlite(v)))
                        .collect()
                })
                .collect();
            let deletes: Vec<Vec<(String, SValue)>> = changes
                .deletes
                .iter()
                .map(|row| {
                    row.iter()
                        .map(|(k, v)| (k.clone(), crate::driver::json_to_sqlite(v)))
                        .collect()
                })
                .collect();
            tauri::async_runtime::spawn_blocking(move || {
                db.apply_changes(&t, &updates, &inserts, &deletes)
            })
            .await
            .map_err(|e| e.to_string())?
        }
        Active::Mysql(pool) => {
            let db = database.ok_or_else(|| "database is required for mysql".to_string())?;
            mysql::apply_changes(
                pool,
                &db,
                &table,
                &changes.updates,
                &changes.inserts,
                &changes.deletes,
            )
            .await
        }
    }
}

// ---------------- SQL 执行 ----------------

#[tauri::command]
pub async fn execute_sql(
    state: State<'_, AppState>,
    id: String,
    sql: String,
) -> Result<Vec<QueryResult>, String> {
    let started = now_ms();
    let active = active_of(&state, &id)?;
    let outcome = match &active {
        Active::Sqlite(db) => {
            let db = db.clone();
            let sql2 = sql.clone();
            tauri::async_runtime::spawn_blocking(move || db.run_script(&sql2))
                .await
                .map_err(|e| e.to_string())?
        }
        Active::Mysql(pool) => mysql::run_script(pool, &sql).await,
    };
    if let Ok(store) = get_store(&state) {
        let (dur, rows, err) = match &outcome {
            Ok(list) => {
                let total_rows: usize = list
                    .iter()
                    .map(|r| r.rows.len() + r.affected_rows)
                    .sum();
                (Some(now_ms() - started), Some(total_rows as i64), None)
            }
            Err(e) => (Some(now_ms() - started), None, Some(e.clone())),
        };
        store.add_history(Some(&id), &sql, dur, rows, err.as_deref());
    }
    outcome
}

#[tauri::command]
pub async fn apply_ddl(
    state: State<'_, AppState>,
    id: String,
    statements: Vec<String>,
) -> Result<Vec<QueryResult>, String> {
    let sql = statements.join(";\n");
    execute_sql(state, id, sql).await
}

#[tauri::command]
pub async fn get_table_ddl(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: String,
) -> Result<String, String> {
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => db.table_ddl(&table),
        Active::Mysql(pool) => {
            let db = database.ok_or_else(|| "database is required for mysql".to_string())?;
            mysql::table_ddl(pool, &db, &table).await
        }
    }
}

// ---------------- 历史 ----------------

#[tauri::command]
pub async fn list_history(
    state: State<'_, AppState>,
    limit: Option<i64>,
) -> Result<Vec<HistoryEntry>, String> {
    let store = get_store(&state)?;
    store.list_history(limit.unwrap_or(200))
}

#[tauri::command]
pub async fn clear_history(state: State<'_, AppState>) -> Result<(), String> {
    let store = get_store(&state)?;
    store.clear_history()
}

// ---------------- 导入导出 ----------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportDone {
    pub rows: usize,
    pub path: String,
}

/// table 与 sql 二选一；path 由前端 dialog.save 取得
#[tauri::command]
pub async fn export_result(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: Option<String>,
    sql: Option<String>,
    path: String,
    format: String, // csv | json
) -> Result<ExportDone, String> {
    let active = active_of(&state, &id)?;
    let q: QueryResult = match (table.as_deref(), sql.as_deref()) {
        (Some(t), _) => match &active {
            Active::Sqlite(db) => db.query_all(&format!(
                "SELECT * FROM {}",
                crate::driver::quote_ident("sqlite", t)
            ))?,
            Active::Mysql(pool) => {
                let qualified =
                    crate::driver::quote_qualified("mysql", database.as_deref(), t);
                mysql::exec_one(pool, &format!("SELECT * FROM {qualified}")).await?
            }
        },
        (_, Some(s)) => match &active {
            Active::Sqlite(db) => db.query_all(s)?,
            Active::Mysql(pool) => mysql::exec_one(pool, s).await?,
        },
        _ => return Err("table or sql is required".into()),
    };
    let rows = write_export_file(&path, &q, &format)?;
    Ok(ExportDone { rows, path })
}

fn write_export_file(path: &str, q: &QueryResult, format: &str) -> Result<usize, String> {
    use std::io::Write;
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut w = std::io::BufWriter::new(file);
    match format {
        "json" => {
            let mut arr = Vec::with_capacity(q.rows.len());
            for row in &q.rows {
                let mut obj = serde_json::Map::new();
                for (i, c) in q.columns.iter().enumerate() {
                    obj.insert(
                        c.clone(),
                        row.get(i).cloned().unwrap_or(serde_json::Value::Null),
                    );
                }
                arr.push(serde_json::Value::Object(obj));
            }
            serde_json::to_writer_pretty(&mut w, &arr).map_err(|e| e.to_string())?;
        }
        _ => {
            let mut cw = csv::Writer::from_writer(&mut w);
            cw.write_record(&q.columns).map_err(|e| e.to_string())?;
            for row in &q.rows {
                let rec: Vec<String> = row
                    .iter()
                    .map(|v| match v {
                        serde_json::Value::Null => String::new(),
                        serde_json::Value::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect();
                cw.write_record(&rec).map_err(|e| e.to_string())?;
            }
            cw.flush().map_err(|e| e.to_string())?;
        }
    }
    w.flush().map_err(|e| e.to_string())?;
    Ok(q.rows.len())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CsvPreview {
    pub columns: Vec<String>,
    pub sample: Vec<Vec<String>>,
    pub total_rows: usize,
}

#[tauri::command]
pub async fn import_preview(path: String) -> Result<CsvPreview, String> {
    let mut rdr = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_path(&path)
        .map_err(|e| e.to_string())?;
    let headers: Vec<String> = rdr
        .headers()
        .map_err(|e| e.to_string())?
        .iter()
        .map(|h| h.to_string())
        .collect();
    let mut sample = Vec::new();
    let mut total = 0usize;
    for rec in rdr.records() {
        let rec = rec.map_err(|e| e.to_string())?;
        if sample.len() < 50 {
            sample.push(rec.iter().map(|f| f.to_string()).collect());
        }
        total += 1;
    }
    Ok(CsvPreview {
        columns: headers,
        sample,
        total_rows: total,
    })
}

/// CSV 导入：mapping 为 (csv 列下标 -> 目标表列名) 列表（前端列映射确认后传入）
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CsvColumnMap {
    pub csv_index: usize,
    pub column: String,
}

#[tauri::command]
pub async fn import_csv(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: String,
    path: String,
    mapping: Vec<CsvColumnMap>,
    null_empty: bool,
) -> Result<usize, String> {
    if mapping.is_empty() {
        return Err("no column mapping".into());
    }
    let columns: Vec<String> = mapping.iter().map(|m| m.column.clone()).collect();
    let rows: Vec<Vec<Option<String>>> = {
        let mut rdr = csv::ReaderBuilder::new()
            .has_headers(true)
            .flexible(true)
            .from_path(&path)
            .map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for rec in rdr.records() {
            let rec = rec.map_err(|e| e.to_string())?;
            out.push(
                mapping
                    .iter()
                    .map(|m| rec.get(m.csv_index).map(|s| s.to_string()))
                    .collect(),
            );
        }
        out
    };
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => {
            let db = db.clone();
            let t = table.clone();
            let cols = columns.clone();
            let vals: Vec<Vec<SValue>> = rows
                .iter()
                .map(|row| row.iter().map(|f| csv_cell_to_sqlite(f, null_empty)).collect())
                .collect();
            tauri::async_runtime::spawn_blocking(move || db.import_rows(&t, &cols, &vals))
                .await
                .map_err(|e| e.to_string())?
        }
        Active::Mysql(pool) => {
            let db = database.ok_or_else(|| "database is required for mysql".to_string())?;
            let vals: Vec<Vec<serde_json::Value>> = rows
                .iter()
                .map(|row| row.iter().map(|f| csv_cell_to_json(f, null_empty)).collect())
                .collect();
            mysql::import_rows(pool, &db, &table, &columns, &vals).await
        }
    }
}


#[tauri::command]
pub async fn import_rows(
    state: State<'_, AppState>,
    id: String,
    database: Option<String>,
    table: String,
    columns: Vec<String>,
    rows: Vec<Vec<Option<String>>>,
    null_empty: bool,
) -> Result<usize, String> {
    let active = active_of(&state, &id)?;
    match &active {
        Active::Sqlite(db) => {
            let db = db.clone();
            let cols = columns.clone();
            let t = table.clone();
            let vals: Vec<Vec<SValue>> = rows
                .iter()
                .map(|row| row.iter().map(|f| csv_cell_to_sqlite(f, null_empty)).collect())
                .collect();
            tauri::async_runtime::spawn_blocking(move || db.import_rows(&t, &cols, &vals))
                .await
                .map_err(|e| e.to_string())?
        }
        Active::Mysql(pool) => {
            let db = database.ok_or_else(|| "database is required for mysql".to_string())?;
            let vals: Vec<Vec<serde_json::Value>> = rows
                .iter()
                .map(|row| row.iter().map(|f| csv_cell_to_json(f, null_empty)).collect())
                .collect();
            mysql::import_rows(pool, &db, &table, &columns, &vals).await
        }
    }
}

fn csv_cell_to_sqlite(v: &Option<String>, null_empty: bool) -> SValue {
    match v {
        None => SValue::Null,
        Some(s) if s.is_empty() && null_empty => SValue::Null,
        Some(s) => match s.parse::<i64>() {
            Ok(i) => SValue::Integer(i),
            Err(_) => match s.parse::<f64>() {
                Ok(f) => SValue::Real(f),
                Err(_) => SValue::Text(s.clone()),
            },
        },
    }
}

fn csv_cell_to_json(v: &Option<String>, null_empty: bool) -> serde_json::Value {
    match v {
        None => serde_json::Value::Null,
        Some(s) if s.is_empty() && null_empty => serde_json::Value::Null,
        Some(s) => match s.parse::<i64>() {
            Ok(i) => json!(i),
            Err(_) => match s.parse::<f64>() {
                Ok(f) => json!(f),
                Err(_) => json!(s),
            },
        },
    }
}
