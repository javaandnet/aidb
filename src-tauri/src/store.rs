//! 应用配置库：连接档案 / SQL 执行历史
//! 所有表包含 created_at / updated_at / created_by / updated_by 审计字段。
//! 密码不入库，经 macOS Keychain（keyring crate, service = "aidb"）存储。

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionProfile {
    pub id: String,
    pub name: String,
    /// "sqlite" | "mysql"
    pub kind: String,
    pub file_path: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub user: Option<String>,
    pub default_db: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub created_by: String,
    pub updated_by: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: i64,
    pub connection_id: Option<String>,
    pub sql: String,
    pub duration_ms: Option<i64>,
    pub row_count: Option<i64>,
    pub error: Option<String>,
    pub created_at: i64,
}

pub struct Store {
    pub conn: Mutex<Connection>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl Store {
    pub fn open(path: &std::path::Path) -> Result<Store, String> {
        let conn = Connection::open(path).map_err(|e| e.to_string())?;
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS connection (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                file_path TEXT,
                host TEXT,
                port INTEGER,
                user TEXT,
                default_db TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                created_by TEXT NOT NULL,
                updated_by TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sql_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                connection_id TEXT,
                sql TEXT NOT NULL,
                duration_ms INTEGER,
                row_count INTEGER,
                error TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                created_by TEXT NOT NULL,
                updated_by TEXT NOT NULL
            );
            "#,
        )
        .map_err(|e| e.to_string())?;
        Ok(Store { conn: Mutex::new(conn) })
    }

    pub fn list_connections(&self) -> Result<Vec<ConnectionProfile>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id,name,kind,file_path,host,port,user,default_db,created_at,updated_at,created_by,updated_by
                 FROM connection ORDER BY created_at",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok(ConnectionProfile {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    kind: r.get(2)?,
                    file_path: r.get(3)?,
                    host: r.get(4)?,
                    port: r.get::<_, Option<i64>>(5)?.map(|v| v as u16),
                    user: r.get(6)?,
                    default_db: r.get(7)?,
                    created_at: r.get(8)?,
                    updated_at: r.get(9)?,
                    created_by: r.get(10)?,
                    updated_by: r.get(11)?,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    /// upsert：存在则更新（保留 created_at/created_by），否则插入
    pub fn save_connection(&self, p: &ConnectionProfile) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        let now = now_ms();
        let old: Option<(i64, String)> = conn
            .query_row(
                "SELECT created_at, created_by FROM connection WHERE id = ?1",
                params![p.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .ok();
        let (created_at, created_by) = match old {
            Some((ts, by)) => (ts, by),
            None => (now, "local".to_string()),
        };
        conn.execute(
            r#"INSERT INTO connection (id,name,kind,file_path,host,port,user,default_db,
                 created_at,updated_at,created_by,updated_by)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
               ON CONFLICT(id) DO UPDATE SET
                 name=?2, kind=?3, file_path=?4, host=?5, port=?6, user=?7, default_db=?8,
                 updated_at=?10, updated_by=?12"#,
            params![
                p.id, p.name, p.kind, p.file_path, p.host,
                p.port.map(|v| v as i64), p.user, p.default_db,
                created_at, now, created_by, "local"
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn delete_connection(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM connection WHERE id = ?1", params![id])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn add_history(
        &self,
        connection_id: Option<&str>,
        sql: &str,
        duration_ms: Option<i64>,
        row_count: Option<i64>,
        error: Option<&str>,
    ) {
        let conn = self.conn.lock().unwrap();
        let now = now_ms();
        let _ = conn.execute(
            r#"INSERT INTO sql_history (connection_id,sql,duration_ms,row_count,error,
                 created_at,updated_at,created_by,updated_by)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)"#,
            params![connection_id, sql, duration_ms, row_count, error, now, now, "local", "local"],
        );
    }

    pub fn list_history(&self, limit: i64) -> Result<Vec<HistoryEntry>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id,connection_id,sql,duration_ms,row_count,error,created_at
                 FROM sql_history ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit], |r| {
                Ok(HistoryEntry {
                    id: r.get(0)?,
                    connection_id: r.get(1)?,
                    sql: r.get(2)?,
                    duration_ms: r.get(3)?,
                    row_count: r.get(4)?,
                    error: r.get(5)?,
                    created_at: r.get(6)?,
                })
            })
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn clear_history(&self) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM sql_history", [])
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// ---- macOS Keychain 密码存取 ----

pub fn keyring_account(connection_id: &str) -> String {
    format!("conn:{connection_id}")
}

pub fn set_password(connection_id: &str, password: &str) -> Result<(), String> {
    let entry = keyring::Entry::new("aidb", &keyring_account(connection_id))
        .map_err(|e| e.to_string())?;
    entry.set_password(password).map_err(|e| e.to_string())
}

pub fn get_password(connection_id: &str) -> Option<String> {
    let entry = keyring::Entry::new("aidb", &keyring_account(connection_id)).ok()?;
    entry.get_password().ok()
}

pub fn delete_password(connection_id: &str) {
    if let Ok(entry) = keyring::Entry::new("aidb", &keyring_account(connection_id)) {
        let _ = entry.delete_credential();
    }
}
