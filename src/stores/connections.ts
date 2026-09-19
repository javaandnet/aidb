// 连接与 schema 状态
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { api } from '../api'
import type { ConnectionProfile, TableInfo, ColumnInfo } from '../types'

export interface TableTreeNode {
  id: string
  name: string
  kind: 'table' | 'view'
  database: string | null
}

export const useConnStore = defineStore('connections', () => {
  const profiles = ref<ConnectionProfile[]>([])
  const connectedId = ref<string | null>(null)
  // MySQL 当前库（sqlite 为 null）
  const currentDb = ref<string | null>(null)
  const databases = ref<string[]>([])
  const tables = ref<TableInfo[]>([])
  const columnCache = ref<Record<string, ColumnInfo[]>>({})

  const connected = computed(() => profiles.value.find(p => p.id === connectedId.value) ?? null)
  const kind = computed(() => connected.value?.kind ?? null)

  async function loadProfiles() {
    profiles.value = await api.listConnections()
  }

  async function connect(p: ConnectionProfile, password?: string | null) {
    await api.connect(p.id, password)
    connectedId.value = p.id
    currentDb.value = p.kind === 'mysql' ? p.defaultDb ?? null : null
    await refreshTree()
  }

  async function disconnect() {
    if (connectedId.value) await api.disconnect(connectedId.value)
    connectedId.value = null
    databases.value = []
    tables.value = []
    currentDb.value = null
  }

  /** MySQL 切换当前库 */
  async function useDatabase(db: string) {
    currentDb.value = db
    await refreshTree()
  }

  async function refreshTree() {
    if (!connectedId.value) return
    tables.value = []
    const payload = await api.getSchema(connectedId.value, currentDb.value)
    if (payload.databases) {
      databases.value = payload.databases
    } else {
      tables.value = payload.tables
      // MySQL 已选库时，额外拉一次库列表供顶栏切换器使用
      if (kind.value === 'mysql' && !databases.value.length) {
        try {
          const all = await api.getSchema(connectedId.value, null)
          databases.value = all.databases ?? []
        } catch { /* 忽略 */ }
      }
    }
  }

  async function columnsOf(table: string): Promise<ColumnInfo[]> {
    if (!connectedId.value) return []
    const key = `${connectedId.value}:${currentDb.value ?? ''}:${table}`
    if (!columnCache.value[key]) {
      columnCache.value[key] = await api.listColumns(connectedId.value, currentDb.value, table)
    }
    return columnCache.value[key]
  }

  function invalidateColumns(table?: string) {
    if (table) {
      for (const k of Object.keys(columnCache.value)) {
        if (k.endsWith(`:${table}`)) delete columnCache.value[k]
      }
    } else {
      columnCache.value = {}
    }
  }

  return {
    profiles, connectedId, connected, kind, currentDb, databases, tables,
    loadProfiles, connect, disconnect, useDatabase, refreshTree, columnsOf, invalidateColumns,
  }
})
