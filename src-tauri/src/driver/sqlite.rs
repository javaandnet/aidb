//! SQLite 驱动（rusqlite, bundled）

use super::{
    big_int_to_json, is_readonly_stmt, json_to_sqlite, quote_ident, split_statements, ColumnInfo,
    PageResult, QueryResult, RowChange, TableInfo,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rusqlite::{types::Value as SValue, types::ValueRef, Connection};
use std::sync::Mutex;
use std::time::Instant;

pub struct SqliteDb {
    pub conn: Mutex<Connection>,
}

fn map_err<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

impl SqliteDb {
    pub fn open(path: &str) -> Result<SqliteDb, String> {
        let conn = Connection::open(path).map_err(map_err)?;
        // 外键约束与 busy 超时，贴近常用客户端行为
        let _ = conn.pragma_update(None, "foreign_keys", "ON");
        let _ = conn.busy_timeout(std::time::Duration::from_millis(5000));
        Ok(SqliteDb { conn: Mutex::new(conn) })
    }

    pub fn list_tables(&self) -> Result<Vec<TableInfo>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT name, type FROM sqlite_master
                 WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
                 ORDER BY name",
            )
            .map_err(map_err)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(TableInfo {
                    name: r.get(0)?,
                    schema: "main".into(),
                    kind: r.get(1)?,
                })
            })
            .map_err(map_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_err)
    }

    pub fn list_columns(&self, table: &str) -> Result<Vec<ColumnInfo>, String> {
        let conn = self.conn.lock().unwrap();
        let sql = format!("PRAGMA table_info({})", quote_ident("sqlite", table));
        let mut stmt = conn.prepare(&sql).map_err(map_err)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(ColumnInfo {
                    name: r.get::<_, String>("name")?,
                    data_type: r.get::<_, String>("type").unwrap_or_default(),
                    not_null: r.get::<_, i64>("notnull").unwrap_or(0) != 0,
                    default: r.get::<_, Option<String>>("dflt_value").ok().flatten(),
                    pk_pos: r
                        .get::<_, i64>("pk")
                        .ok()
                        .filter(|v| *v > 0),
                    extra: None,
                })
            })
            .map_err(map_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_err)
    }

    pub fn table_ddl(&self, table: &str) -> Result<String, String> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT sql FROM sqlite_master WHERE name = ?1 AND sql IS NOT NULL",
            rusqlite::params![table],
            |r| r.get::<_, String>(0),
        )
        .map_err(map_err)
    }

    fn columns_or_err(&self, table: &str) -> Result<Vec<ColumnInfo>, String> {
        let cols = self.list_columns(table)?;
        if cols.is_empty() {
            return Err(format!("table not found or has no columns: {table}"));
        }
        Ok(cols)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn query_page(
        &self,
        table: &str,
        where_sql: Option<&str>,
        order_col: Option<&str>,
        order_dir: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> Result<PageResult, String> {
        let cols = self.columns_or_err(table)?;
        let col_names: Vec<String> = cols.iter().map(|c| c.name.clone()).collect();
        let quoted: Vec<String> = col_names
            .iter()
            .map(|n| quote_ident("sqlite", n))
            .collect();
        let where_clause = where_sql
            .map(|w| w.trim().to_string())
            .filter(|w| !w.is_empty())
            .map(|w| format!(" WHERE {w}"))
            .unwrap_or_default();
        let order_clause = match order_col {
            Some(c) if col_names.iter().any(|n| n == c) => {
                let dir = if order_dir == Some("DESC") { "DESC" } else { "ASC" };
                format!(" ORDER BY {} {dir}", quote_ident("sqlite", c))
            }
            _ => String::new(),
        };
        let conn = self.conn.lock().unwrap();
        let t0 = Instant::now();
        let total: i64 = conn
            .query_row(
                &format!("SELECT COUNT(*) FROM {}{where_clause}", quote_ident("sqlite", table)),
                [],
                |r| r.get(0),
            )
            .map_err(map_err)?;
        let sql = format!(
            "SELECT {} FROM {}{where_clause}{order_clause} LIMIT {} OFFSET {}",
            quoted.join(", "),
            quote_ident("sqlite", table),
            limit.max(1),
            offset.max(0)
        );
        let mut result = exec_to_result(&conn, &sql, &[])?;
        result.elapsed_ms = t0.elapsed().as_millis() as u64;
        Ok(PageResult { total, result })
    }

    /// 逐条执行多条语句，返回每条的结果
    pub fn run_script(&self, sql: &str) -> Result<Vec<QueryResult>, String> {
        let conn = self.conn.lock().unwrap();
        let mut out = Vec::new();
        for stmt_sql in split_statements(sql) {
            out.push(exec_to_result(&conn, &stmt_sql, &[])?);
        }
        Ok(out)
    }

    /// 网格编辑回写：updates/inserts/deletes，全部参数化绑定
    pub fn apply_changes(
        &self,
        table: &str,
        updates: &[RowChange],
        inserts: &[Vec<(String, SValue)>],
        deletes: &[Vec<(String, SValue)>],
    ) -> Result<usize, String> {
        let cols = self.columns_or_err(table)?;
        let valid: std::collections::HashSet<&str> =
            cols.iter().map(|c| c.name.as_str()).collect();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(map_err)?;
        let mut written = 0usize;
        for u in updates {
            let set: Vec<(String, SValue)> = u
                .set
                .iter()
                .map(|(k, v)| (k.clone(), json_to_sqlite(v)))
                .collect();
            let pk: Vec<(String, SValue)> = u
                .pk
                .iter()
                .map(|(k, v)| (k.clone(), json_to_sqlite(v)))
                .collect();
            for (k, _) in set.iter().chain(pk.iter()) {
                if !valid.contains(k.as_str()) {
                    return Err(format!("unknown column: {k}"));
                }
            }
            if pk.is_empty() {
                return Err("row has no primary key".into());
            }
            let sets: Vec<String> = set.iter().map(|(k, _)| format!("{} = ?", quote_ident("sqlite", k))).collect();
            let whs: Vec<String> = pk.iter().map(|(k, _)| pk_cond("sqlite", k)).collect();
            let sql = format!(
                "UPDATE {} SET {} WHERE {}",
                quote_ident("sqlite", table),
                sets.join(", "),
                whs.join(" AND ")
            );
            let vals: Vec<SValue> = set.into_iter().map(|(_, v)| v).chain(pk.into_iter().map(|(_, v)| v)).collect();
            written += exec_params(&tx, &sql, &vals)?;
        }
        for row in inserts {
            if row.is_empty() {
                continue;
            }
            for (k, _) in row.iter() {
                if !valid.contains(k.as_str()) {
                    return Err(format!("unknown column: {k}"));
                }
            }
            let names: Vec<String> = row.iter().map(|(k, _)| quote_ident("sqlite", k)).collect();
            let marks = vec!["?"; row.len()].join(", ");
            let sql = format!(
                "INSERT INTO {} ({}) VALUES ({})",
                quote_ident("sqlite", table),
                names.join(", "),
                marks
            );
            let vals: Vec<SValue> = row.iter().map(|(_, v)| v.clone()).collect();
            written += exec_params(&tx, &sql, &vals)?;
        }
        for pk in deletes {
            for (k, _) in pk.iter() {
                if !valid.contains(k.as_str()) {
                    return Err(format!("unknown column: {k}"));
                }
            }
            if pk.is_empty() {
                return Err("row has no primary key".into());
            }
            let whs: Vec<String> = pk.iter().map(|(k, _)| pk_cond("sqlite", k)).collect();
            let sql = format!(
                "DELETE FROM {} WHERE {}",
                quote_ident("sqlite", table),
                whs.join(" AND ")
            );
            let vals: Vec<SValue> = pk.iter().map(|(_, v)| v.clone()).collect();
            written += exec_params(&tx, &sql, &vals)?;
        }
        tx.commit().map_err(map_err)?;
        Ok(written)
    }

    /// 导出用：整表/任意 SQL 查询取全部行
    pub fn query_all(&self, sql: &str) -> Result<QueryResult, String> {
        let conn = self.conn.lock().unwrap();
        exec_to_result(&conn, sql, &[])
    }

    /// 导入用：批量参数化 INSERT
    pub fn import_rows(
        &self,
        table: &str,
        columns: &[String],
        rows: &[Vec<SValue>],
    ) -> Result<usize, String> {
        let cols = self.columns_or_err(table)?;
        let valid: std::collections::HashSet<&str> =
            cols.iter().map(|c| c.name.as_str()).collect();
        for k in columns {
            if !valid.contains(k.as_str()) {
                return Err(format!("unknown column: {k}"));
            }
        }
        let names: Vec<String> = columns.iter().map(|k| quote_ident("sqlite", k)).collect();
        let marks = vec!["?"; columns.len()].join(", ");
        let sql = format!(
            "INSERT INTO {} ({}) VALUES ({})",
            quote_ident("sqlite", table),
            names.join(", "),
            marks
        );
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction().map_err(map_err)?;
        let mut n = 0usize;
        for row in rows {
            n += exec_params(&tx, &sql, row)?;
        }
        tx.commit().map_err(map_err)?;
        Ok(n)
    }
}

fn pk_cond(kind: &str, k: &str) -> String {
    let id = quote_ident(kind, k);
    // NULL 主键列（理论上不该出现）用 IS NULL 兜底
    format!("{id} = ?")
}

trait Execable {
    fn prep_exec(&self, sql: &str) -> Result<rusqlite::Statement, String>;
}
impl Execable for Connection {
    fn prep_exec(&self, sql: &str) -> Result<rusqlite::Statement, String> {
        self.prepare(sql).map_err(map_err)
    }
}
impl<'t> Execable for rusqlite::Transaction<'t> {
    fn prep_exec(&self, sql: &str) -> Result<rusqlite::Statement, String> {
        self.prepare(sql).map_err(map_err)
    }
}

/// 执行单条带参 SQL（非查询），返回影响行数
pub fn exec_params<E: Execable>(e: &E, sql: &str, vals: &[SValue]) -> Result<usize, String> {
    let mut stmt = e.prep_exec(sql)?;
    let params: Vec<&dyn rusqlite::ToSql> =
        vals.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
    stmt.execute(rusqlite::params_from_iter(params.iter()))
        .map_err(map_err)
}

/// 执行一条 SQL，自动判断是否有结果集
fn exec_to_result(conn: &Connection, sql: &str, vals: &[SValue]) -> Result<QueryResult, String> {
    let t0 = Instant::now();
    let mut stmt = conn.prepare(sql).map_err(map_err)?;
    let params: Vec<&dyn rusqlite::ToSql> =
        vals.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
    let columns: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
    let is_query = !columns.is_empty();
    let (rows, blob_columns, affected) = if is_query {
        let mut blob_set: std::collections::HashSet<usize> = std::collections::HashSet::new();
        let mut rows: Vec<Vec<serde_json::Value>> = Vec::new();
        let mut mapped = stmt.query(rusqlite::params_from_iter(params.iter())).map_err(map_err)?;
        while let Some(row) = mapped.next().map_err(map_err)? {
            let mut v = Vec::with_capacity(columns.len());
            for i in 0..columns.len() {
                let cell = row.get_ref(i).map_err(map_err)?;
                if matches!(cell, ValueRef::Blob(_)) {
                    blob_set.insert(i);
                }
                v.push(cell_json(cell));
            }
            rows.push(v);
        }
        let mut blobs: Vec<usize> = blob_set.into_iter().collect();
        blobs.sort();
        (rows, blobs, 0usize)
    } else {
        let affected = stmt
            .execute(rusqlite::params_from_iter(params.iter()))
            .map_err(map_err)?;
        (Vec::new(), Vec::new(), affected)
    };
    Ok(QueryResult {
        columns,
        rows,
        blob_columns,
        affected_rows: affected,
        elapsed_ms: t0.elapsed().as_millis() as u64,
        is_query: is_query || is_readonly_stmt(sql),
        statement: sql.to_string(),
    })
}

/// rusqlite ValueRef -> serde_json::Value（BLOB -> base64，大整数 -> 字符串）
pub fn cell_json(v: ValueRef) -> serde_json::Value {
    match v {
        ValueRef::Null => serde_json::Value::Null,
        ValueRef::Integer(i) => big_int_to_json(i),
        ValueRef::Real(f) => serde_json::Number::from_f64(f)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::String(f.to_string())),
        ValueRef::Text(t) => serde_json::Value::String(String::from_utf8_lossy(t).into_owned()),
        ValueRef::Blob(b) => serde_json::Value::String(B64.encode(b)),
    }
}
