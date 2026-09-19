// 与 Rust 侧 serde(camelCase) 对应的类型定义

export interface ConnectionProfile {
  id: string
  name: string
  kind: 'sqlite' | 'mysql'
  filePath?: string | null
  host?: string | null
  port?: number | null
  user?: string | null
  defaultDb?: string | null
  createdAt: number
  updatedAt: number
  createdBy: string
  updatedBy: string
}

export interface ConnectionInput {
  id: string
  name: string
  kind: string
  filePath?: string | null
  host?: string | null
  port?: number | null
  user?: string | null
  defaultDb?: string | null
}

export interface TableInfo {
  name: string
  schema: string
  kind: 'table' | 'view'
}

export interface ColumnInfo {
  name: string
  dataType: string
  notNull: boolean
  default: string | null
  pkPos: number | null
  extra: string | null
}

export interface QueryResult {
  columns: string[]
  rows: any[][]
  blobColumns: number[]
  affectedRows: number
  elapsedMs: number
  isQuery: boolean
  statement: string
}

export interface PageResult extends QueryResult {
  total: number
}

export interface SchemaPayload {
  kind: string
  databases: string[] | null
  tables: TableInfo[]
}

export interface HistoryEntry {
  id: number
  connectionId: string | null
  sql: string
  durationMs: number | null
  rowCount: number | null
  error: string | null
  createdAt: number
}

export interface CsvPreview {
  columns: string[]
  sample: string[][]
  totalRows: number
}

export interface ExportDone {
  rows: number
  path: string
}

export type CellValue = any
