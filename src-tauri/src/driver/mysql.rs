//! MySQL 驱动（mysql_async 0.37，纯 Rust）

use super::{
    big_int_to_json, is_readonly_stmt, quote_ident, quote_qualified, split_statements, ColumnInfo,
    PageResult, QueryResult, RowChange, TableInfo,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use mysql_async::prelude::*;
use mysql_async::{OptsBuilder, Params, Pool, Value as MValue};
use std::sync::Arc;
use std::time::Instant;

pub type MysqlPool = Arc<Pool>;

fn err<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

pub fn build_pool(
    host: &str,
    port: u16,
    user: &str,
    password: &str,
    database: Option<&str>,
) -> MysqlPool {
    let mut builder = OptsBuilder::default()
        .ip_or_hostname(host.to_string())
        .tcp_port(port)
        .user(Some(user.to_string()))
        .pass(Some(password.to_string()))
        .prefer_socket(false);
    if let Some(db) = database {
        if !db.is_empty() {
            builder = builder.db_name(Some(db.to_string()));
        }
    }
    Arc::new(Pool::new(builder))
}

/// 执行单条 SQL（自动区分结果集/影响行数）
pub async fn exec_one(pool: &MysqlPool, sql: &str) -> Result<QueryResult, String> {
    let t0 = Instant::now();
    let mut conn = pool.get_conn().await.map_err(err)?;
    let mut iter = conn.query_iter(sql).await.map_err(err)?;
    let columns: Vec<String> = iter
        .columns_ref()
        .iter()
        .map(|c| c.name_str().into_owned())
        .collect();
    let mut rows: Vec<Vec<serde_json::Value>> = Vec::new();
    let mut blob_flags: Vec<bool> = vec![false; columns.len()];
    while let Some(row) = iter.next().await.map_err(err)? {
        let vals: Vec<MValue> = row.unwrap();
        let mut cells = Vec::with_capacity(vals.len());
        for (i, v) in vals.into_iter().enumerate() {
            let is_blob = matches!(&v, MValue::Bytes(b) if !std::str::from_utf8(b).is_ok());
            if is_blob && i < blob_flags.len() {
                blob_flags[i] = true;
            }
            cells.push(value_json(v));
        }
        rows.push(cells);
    }
    let blob_columns: Vec<usize> = blob_flags
        .iter()
        .enumerate()
        .filter(|(_, f)| **f)
        .map(|(i, _)| i)
        .collect();
    let affected = iter.affected_rows() as usize;
    drop(iter);
    // PoolConn drop 时自动归还连接池
    Ok(QueryResult {
        columns,
        rows,
        blob_columns,
        affected_rows: affected,
        elapsed_ms: t0.elapsed().as_millis() as u64,
        is_query: is_readonly_stmt(sql),
        statement: sql.to_string(),
    })
}

pub async fn run_script(pool: &MysqlPool, sql: &str) -> Result<Vec<QueryResult>, String> {
    let mut out = Vec::new();
    for s in split_statements(sql) {
        out.push(exec_one(pool, &s).await?);
    }
    Ok(out)
}

/// 执行带参非查询语句，返回影响行数
async fn exec_affected(
    conn: &mut mysql_async::Conn,
    sql: &str,
    vals: Vec<MValue>,
) -> Result<usize, String> {
    let mut qr = conn
        .exec_iter(sql, positioned(&vals))
        .await
        .map_err(err)?;
    while qr.next().await.map_err(err)?.is_some() {}
    let aff = qr.affected_rows() as usize;
    drop(qr);
    Ok(aff)
}

fn positioned(vals: &[MValue]) -> Params {
    Params::Positional(vals.to_vec())
}

pub async fn list_databases(pool: &MysqlPool) -> Result<Vec<String>, String> {
    let r = exec_one(pool, "SHOW DATABASES").await?;
    Ok(r.rows.into_iter().map(|row| cell_to_string(&row[0])).collect())
}

pub async fn list_tables(pool: &MysqlPool, db: &str) -> Result<Vec<TableInfo>, String> {
    let sql = format!(
        "SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = '{}' ORDER BY TABLE_NAME",
        db.replace('\'', "''")
    );
    let r = exec_one(pool, &sql).await?;
    Ok(r.rows
        .into_iter()
        .map(|row| TableInfo {
            name: cell_to_string(&row[0]),
            schema: db.to_string(),
            kind: if cell_to_string(&row[1]).to_ascii_uppercase().contains("VIEW") {
                "view".into()
            } else {
                "table".into()
            },
        })
        .collect())
}

pub async fn list_columns(
    pool: &MysqlPool,
    db: &str,
    table: &str,
) -> Result<Vec<ColumnInfo>, String> {
    let sql = format!(
        "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA
         FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = '{}' AND TABLE_NAME = '{}'
         ORDER BY ORDINAL_POSITION",
        db.replace('\'', "''"),
        table.replace('\'', "''")
    );
    let r = exec_one(pool, &sql).await?;
    Ok(r.rows
        .into_iter()
        .enumerate()
        .map(|(i, row)| ColumnInfo {
            name: cell_to_string(&row[0]),
            data_type: cell_to_string(&row[1]),
            not_null: cell_to_string(&row[2]) == "NO",
            default: row.get(3).cloned().filter(|v| !v.is_null()).map(|v| cell_to_string(&v)),
            pk_pos: if cell_to_string(&row[4]).to_ascii_uppercase() == "PRI" {
                Some(i as i64 + 1)
            } else {
                None
            },
            extra: row.get(5).cloned().filter(|v| !v.is_null()).map(|v| cell_to_string(&v)),
        })
        .collect())
}

pub async fn table_ddl(pool: &MysqlPool, db: &str, table: &str) -> Result<String, String> {
    let sql = format!("SHOW CREATE TABLE {}", quote_qualified("mysql", Some(db), table));
    let r = exec_one(pool, &sql).await?;
    r.rows
        .first()
        .and_then(|row| row.get(1))
        .map(cell_to_string)
        .ok_or_else(|| "ddl not found".into())
}

#[allow(clippy::too_many_arguments)]
pub async fn query_page(
    pool: &MysqlPool,
    db: &str,
    table: &str,
    where_sql: Option<&str>,
    order_col: Option<&str>,
    order_dir: Option<&str>,
    limit: i64,
    offset: i64,
) -> Result<PageResult, String> {
    let cols = list_columns(pool, db, table).await?;
    if cols.is_empty() {
        return Err(format!("table not found: {db}.{table}"));
    }
    let qualified = quote_qualified("mysql", Some(db), table);
    let where_clause = where_sql
        .map(|w| w.trim().to_string())
        .filter(|w| !w.is_empty())
        .map(|w| format!(" WHERE {w}"))
        .unwrap_or_default();
    let order_clause = match order_col {
        Some(c) if cols.iter().any(|n| n.name == c) => {
            let dir = if order_dir == Some("DESC") { "DESC" } else { "ASC" };
            format!(" ORDER BY {} {dir}", quote_ident("mysql", c))
        }
        _ => String::new(),
    };
    let t0 = Instant::now();
    let total_r = exec_one(
        pool,
        &format!("SELECT COUNT(*) FROM {qualified}{where_clause}"),
    )
    .await?;
    let total = total_r
        .rows
        .first()
        .and_then(|r| r.first())
        .and_then(|v| v.as_i64_compat())
        .unwrap_or(0);
    let select_list: Vec<String> = cols
        .iter()
        .map(|c| quote_ident("mysql", &c.name))
        .collect();
    let sql = format!(
        "SELECT {} FROM {qualified}{where_clause}{order_clause} LIMIT {} OFFSET {}",
        select_list.join(", "),
        limit.max(1),
        offset.max(0)
    );
    let mut result = exec_one(pool, &sql).await?;
    result.elapsed_ms = t0.elapsed().as_millis() as u64;
    Ok(PageResult { total, result })
}

/// 网格编辑回写（全部参数化绑定）
pub async fn apply_changes(
    pool: &MysqlPool,
    db: &str,
    table: &str,
    updates: &[RowChange],
    inserts: &[Vec<(String, serde_json::Value)>],
    deletes: &[Vec<(String, serde_json::Value)>],
) -> Result<usize, String> {
    let cols = list_columns(pool, db, table).await?;
    let valid: std::collections::HashSet<&str> = cols.iter().map(|c| c.name.as_str()).collect();
    let qualified = quote_qualified("mysql", Some(db), table);
    let mut written = 0usize;
    let mut conn = pool.get_conn().await.map_err(err)?;
    for u in updates {
        for (k, _) in u.set.iter().chain(u.pk.iter()) {
            if !valid.contains(k.as_str()) {
                return Err(format!("unknown column: {k}"));
            }
        }
        if u.pk.is_empty() {
            return Err("row has no primary key".into());
        }
        let sets: Vec<String> = u
            .set
            .iter()
            .map(|(k, _)| format!("{} = ?", quote_ident("mysql", k)))
            .collect();
        let whs: Vec<String> = u
            .pk
            .iter()
            .map(|(k, _)| format!("{} = ?", quote_ident("mysql", k)))
            .collect();
        let sql = format!(
            "UPDATE {qualified} SET {} WHERE {}",
            sets.join(", "),
            whs.join(" AND ")
        );
        let vals: Vec<MValue> = u
            .set
            .iter()
            .chain(u.pk.iter())
            .map(|(_, v)| json_to_mysql(v))
            .collect();
        written += exec_affected(&mut conn, &sql, vals).await?;
    }
    for row in inserts {
        for (k, _) in row.iter() {
            if !valid.contains(k.as_str()) {
                return Err(format!("unknown column: {k}"));
            }
        }
        if row.is_empty() {
            continue;
        }
        let names: Vec<String> = row.iter().map(|(k, _)| quote_ident("mysql", k)).collect();
        let marks = vec!["?"; row.len()].join(", ");
        let sql = format!(
            "INSERT INTO {qualified} ({}) VALUES ({})",
            names.join(", "),
            marks
        );
        let vals: Vec<MValue> = row.iter().map(|(_, v)| json_to_mysql(v)).collect();
        written += exec_affected(&mut conn, &sql, vals).await?;
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
        let whs: Vec<String> = pk
            .iter()
            .map(|(k, _)| format!("{} = ?", quote_ident("mysql", k)))
            .collect();
        let sql = format!("DELETE FROM {qualified} WHERE {}", whs.join(" AND "));
        let vals: Vec<MValue> = pk.iter().map(|(_, v)| json_to_mysql(v)).collect();
        written += exec_affected(&mut conn, &sql, vals).await?;
    }
    Ok(written)
}

/// 导入用：批量参数化 INSERT
pub async fn import_rows(
    pool: &MysqlPool,
    db: &str,
    table: &str,
    columns: &[String],
    rows: &[Vec<serde_json::Value>],
) -> Result<usize, String> {
    let cols = list_columns(pool, db, table).await?;
    let valid: std::collections::HashSet<&str> = cols.iter().map(|c| c.name.as_str()).collect();
    for k in columns {
        if !valid.contains(k.as_str()) {
            return Err(format!("unknown column: {k}"));
        }
    }
    let qualified = quote_qualified("mysql", Some(db), table);
    let names: Vec<String> = columns.iter().map(|k| quote_ident("mysql", k)).collect();
    let marks = vec!["?"; columns.len()].join(", ");
    let sql = format!(
        "INSERT INTO {qualified} ({}) VALUES ({})",
        names.join(", "),
        marks
    );
    let mut conn = pool.get_conn().await.map_err(err)?;
    let mut n = 0usize;
    for row in rows {
        let vals: Vec<MValue> = row.iter().map(json_to_mysql).collect();
        exec_affected(&mut conn, &sql, vals).await?;
        n += 1;
    }
    Ok(n)
}

pub fn json_to_mysql(v: &serde_json::Value) -> MValue {
    match v {
        serde_json::Value::Null => MValue::NULL,
        serde_json::Value::Bool(b) => MValue::Int(*b as i64),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                MValue::Int(i)
            } else if let Some(f) = n.as_f64() {
                MValue::Double(f)
            } else {
                MValue::NULL
            }
        }
        serde_json::Value::String(s) => MValue::Bytes(s.clone().into_bytes()),
        other => MValue::Bytes(other.to_string().into_bytes()),
    }
}

pub fn value_json(v: MValue) -> serde_json::Value {
    match v {
        MValue::NULL => serde_json::Value::Null,
        MValue::Bytes(b) => match std::str::from_utf8(&b) {
            Ok(s) => serde_json::Value::String(s.to_string()),
            Err(_) => serde_json::Value::String(B64.encode(&b)),
        },
        MValue::Int(i) => big_int_to_json(i),
        MValue::UInt(u) => big_int_to_json(u as i64),
        MValue::Float(f) => serde_json::Number::from_f64(f as f64)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::String(f.to_string())),
        MValue::Double(d) => serde_json::Number::from_f64(d)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::String(d.to_string())),
        MValue::Date(y, mo, d, h, mi, s, ns) => {
            if h == 0 && mi == 0 && s == 0 && ns == 0 {
                serde_json::Value::String(format!("{y:04}-{mo:02}-{d:02}"))
            } else {
                serde_json::Value::String(format!(
                    "{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}"
                ))
            }
        }
        MValue::Time(neg, days, h, mi, s, ns) => {
            let total = (days as u64) * 86400 + (h as u64) * 3600 + (mi as u64) * 60 + (s as u64);
            let sign = if neg { "-" } else { "" };
            serde_json::Value::String(format!("{sign}{total}.{}s", ns / 1000))
        }
    }
}

pub fn cell_to_string(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Null => String::new(),
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

pub trait AsI64 {
    fn as_i64_compat(&self) -> Option<i64>;
}
impl AsI64 for serde_json::Value {
    fn as_i64_compat(&self) -> Option<i64> {
        match self {
            serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
            serde_json::Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }
}
