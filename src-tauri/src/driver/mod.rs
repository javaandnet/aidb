//! 驱动层公共类型与工具：查询结果结构、SQL 语句拆分、标识符转义等。

pub mod mysql;
pub mod sqlite;

use serde::Serialize;

/// 统一查询结果（列名 + 行数据 + BLOB 列下标 + 影响行数 + 耗时）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryResult {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<serde_json::Value>>,
    /// rows 中按 base64 字符串编码的 BLOB 列下标
    pub blob_columns: Vec<usize>,
    pub affected_rows: usize,
    pub elapsed_ms: u64,
    /// 本语句是否为只读查询（SELECT/PRAGMA/SHOW/DESC/EXPLAIN）
    pub is_query: bool,
    pub statement: String,
}

/// 数据网格分页结果
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageResult {
    pub total: i64,
    #[serde(flatten)]
    pub result: QueryResult,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TableInfo {
    pub name: String,
    /// 所属库（MySQL 为 schema 名；SQLite 固定 "main"）
    pub schema: String,
    /// "table" | "view"
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnInfo {
    pub name: String,
    pub data_type: String,
    pub not_null: bool,
    pub default: Option<String>,
    /// 主键顺序（1 起），None 表示非主键列
    pub pk_pos: Option<i64>,
    pub extra: Option<String>,
}

/// 行变更（按主键定位）：pk = [(列名, 值JSON)]，set = [(列名, 值JSON)]
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowChange {
    pub pk: Vec<(String, serde_json::Value)>,
    pub set: Vec<(String, serde_json::Value)>,
}

pub fn is_readonly_stmt(sql: &str) -> bool {
    let up = sql.trim_start().to_ascii_uppercase();
    up.starts_with("SELECT")
        || up.starts_with("WITH")
        || up.starts_with("PRAGMA")
        || up.starts_with("SHOW")
        || up.starts_with("DESC")
        || up.starts_with("EXPLAIN")
}

/// 拆分多条 SQL 语句：处理字符串引号（' " `）、[标识符]、行注释（--）、块注释。
pub fn split_statements(sql: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let bytes: Vec<char> = sql.chars().collect();
    let mut i = 0usize;
    let mut quote: Option<char> = None; // ' " `
    let mut bracket = false; // [ident]
    while i < bytes.len() {
        let c = bytes[i];
        match quote {
            Some(q) => {
                cur.push(c);
                if c == '\\' && q == '\'' && i + 1 < bytes.len() {
                    // MySQL 风格转义：连下一个字符一并吸收
                    cur.push(bytes[i + 1]);
                    i += 2;
                    continue;
                }
                if c == q {
                    // 双写引号转义 ('' / "" / ``)
                    if i + 1 < bytes.len() && bytes[i + 1] == q {
                        cur.push(bytes[i + 1]);
                        i += 2;
                        continue;
                    }
                    quote = None;
                }
                i += 1;
                continue;
            }
            None => {}
        }
        if bracket {
            cur.push(c);
            if c == ']' {
                bracket = false;
            }
            i += 1;
            continue;
        }
        match c {
            '\'' | '"' | '`' => {
                quote = Some(c);
                cur.push(c);
                i += 1;
            }
            '[' => {
                bracket = true;
                cur.push(c);
                i += 1;
            }
            '-' if i + 1 < bytes.len() && bytes[i + 1] == '-' => {
                // 行注释：吞到行尾
                while i < bytes.len() && bytes[i] != '\n' {
                    cur.push(bytes[i]);
                    i += 1;
                }
            }
            '/' if i + 1 < bytes.len() && bytes[i + 1] == '*' => {
                cur.push(c);
                i += 1;
                while i < bytes.len() && !(bytes[i] == '*' && i + 1 < bytes.len() && bytes[i + 1] == '/') {
                    cur.push(bytes[i]);
                    i += 1;
                }
                if i < bytes.len() {
                    cur.push('*');
                    cur.push('/');
                    i += 2;
                }
            }
            ';' => {
                let t = cur.trim();
                if !t.is_empty() {
                    out.push(t.to_string());
                }
                cur.clear();
                i += 1;
            }
            _ => {
                cur.push(c);
                i += 1;
            }
        }
    }
    let t = cur.trim();
    if !t.is_empty() {
        out.push(t.to_string());
    }
    out
}

/// 标识符转义：sqlite 用双引号（内部 " 双写），mysql 用反引号（内部 ` 加倍）
pub fn quote_ident(kind: &str, name: &str) -> String {
    if kind == "mysql" {
        format!("`{}`", name.replace('`', "``"))
    } else {
        format!("\"{}\"", name.replace('"', "\"\""))
    }
}

pub fn quote_qualified(kind: &str, schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) if !s.is_empty() => format!("{}.{}", quote_ident(kind, s), quote_ident(kind, table)),
        _ => quote_ident(kind, table),
    }
}

/// 表名合法性防御（网格内部使用，标识符仍会转义）
pub fn sanitize_table_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 256 {
        return Err("invalid table name".into());
    }
    Ok(())
}

/// JSON 值 -> SQLite 绑定值
pub fn json_to_sqlite(v: &serde_json::Value) -> rusqlite::types::Value {
    use rusqlite::types::Value as SV;
    match v {
        serde_json::Value::Null => SV::Null,
        serde_json::Value::Bool(b) => SV::Integer(*b as i64),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                SV::Integer(i)
            } else if let Some(f) = n.as_f64() {
                SV::Real(f)
            } else {
                SV::Null
            }
        }
        serde_json::Value::String(s) => SV::Text(s.clone()),
        other => SV::Text(other.to_string()),
    }
}

/// i64 超出 JS 安全整数范围时转字符串，避免前端精度丢失
pub fn big_int_to_json(i: i64) -> serde_json::Value {
    const MAX_SAFE: i128 = 9007199254740991; // 2^53-1
    let v = i as i128;
    if v.abs() > MAX_SAFE {
        serde_json::Value::String(i.to_string())
    } else {
        serde_json::json!(i)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_split_simple() {
        let s = "SELECT 1; SELECT 2;";
        assert_eq!(split_statements(s), vec!["SELECT 1", "SELECT 2"]);
    }

    #[test]
    fn test_split_quoted() {
        let s = "INSERT INTO t VALUES ('a;b''c'); SELECT 2";
        let v = split_statements(s);
        assert_eq!(v.len(), 2);
        assert_eq!(v[0], "INSERT INTO t VALUES ('a;b''c')");
    }

    #[test]
    fn test_split_comment() {
        let s = "-- drop; table\nSELECT 1; /* block; */ SELECT 2";
        let v = split_statements(s);
        assert_eq!(v[0], "-- drop; table\nSELECT 1");
        assert_eq!(v[1], "/* block; */ SELECT 2");
    }

    #[test]
    fn test_quote_ident() {
        assert_eq!(quote_ident("sqlite", "a\"b"), "\"a\"\"b\"");
        assert_eq!(quote_ident("mysql", "a`b"), "`a``b`");
    }

    #[test]
    fn test_big_int() {
        assert_eq!(big_int_to_json(42), serde_json::json!(42));
        assert_eq!(
            big_int_to_json(i64::MAX),
            serde_json::Value::String(i64::MAX.to_string())
        );
    }
}
