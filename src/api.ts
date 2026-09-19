// Tauri invoke 封装：前端所有后端调用的唯一入口
import { invoke } from '@tauri-apps/api/core'
import type {
  ConnectionInput, ConnectionProfile, CsvPreview, ColumnInfo, ExportDone,
  HistoryEntry, PageResult, QueryResult, SchemaPayload,
} from './types'

export const api = {
  // 连接管理
  listConnections: () => invoke<ConnectionProfile[]>('list_connections'),
  saveConnection: (input: ConnectionInput, password?: string | null) =>
    invoke<ConnectionProfile>('save_connection', { input, password: password ?? null }),
  deleteConnection: (id: string) => invoke<void>('delete_connection', { id }),
  testConnection: (input: ConnectionInput, password?: string | null) =>
    invoke<string>('test_connection', { input, password: password ?? null }),
  connect: (id: string, password?: string | null) =>
    invoke<void>('connect', { id, password: password ?? null }),
  disconnect: (id: string) => invoke<void>('disconnect', { id }),

  // schema
  getSchema: (id: string, database?: string | null) =>
    invoke<SchemaPayload>('get_schema', { id, database: database ?? null }),
  listColumns: (id: string, database: string | null, table: string) =>
    invoke<ColumnInfo[]>('list_columns', { id, database, table }),
  getTableDdl: (id: string, database: string | null, table: string) =>
    invoke<string>('get_table_ddl', { id, database, table }),

  // 数据网格
  queryTable: (
    id: string, database: string | null, table: string,
    opts: { whereSql?: string | null; orderCol?: string | null; orderDir?: string | null; limit: number; offset: number },
  ) =>
    invoke<PageResult>('query_table', {
      id, database, table,
      whereSql: opts.whereSql ?? null,
      orderCol: opts.orderCol ?? null,
      orderDir: opts.orderDir ?? null,
      limit: opts.limit,
      offset: opts.offset,
    }),
  applyChanges: (
    id: string, database: string | null, table: string,
    changes: {
      updates: { pk: [string, any][]; set: [string, any][] }[]
      inserts: [string, any][][]
      deletes: [string, any][][]
    },
  ) => invoke<number>('apply_changes', { id, database, table, changes }),

  // SQL
  executeSql: (id: string, sql: string) => invoke<QueryResult[]>('execute_sql', { id, sql }),
  applyDdl: (id: string, statements: string[]) =>
    invoke<QueryResult[]>('apply_ddl', { id, statements }),

  // 历史
  listHistory: (limit?: number) => invoke<HistoryEntry[]>('list_history', { limit: limit ?? null }),
  clearHistory: () => invoke<void>('clear_history'),

  // 导入导出
  exportResult: (
    id: string, database: string | null,
    opts: { table?: string | null; sql?: string | null; path: string; format: 'csv' | 'json' },
  ) =>
    invoke<ExportDone>('export_result', {
      id, database, table: opts.table ?? null, sql: opts.sql ?? null,
      path: opts.path, format: opts.format,
    }),
  importPreview: (path: string) => invoke<CsvPreview>('import_preview', { path }),
  importCsv: (
    id: string, database: string | null, table: string,
    path: string, mapping: { csvIndex: number; column: string }[], nullEmpty: boolean,
  ) => invoke<number>('import_csv', { id, database, table, path, mapping, nullEmpty }),
  importRows: (
    id: string, database: string | null, table: string,
    columns: string[], rows: (string | null)[][], nullEmpty: boolean,
  ) => invoke<number>('import_rows', { id, database, table, columns, rows, nullEmpty }),
}
