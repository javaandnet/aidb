// 多标签工作区状态
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

export type TabType = 'data' | 'sql' | 'structure' | 'history'

export interface WorkspaceTab {
  id: string
  type: TabType
  title: string
  connId: string | null
  database: string | null
  table: string | null
  sql?: string
  pinned?: boolean
}

let seq = 0
function tabId() {
  return `tab_${Date.now().toString(36)}_${++seq}`
}

export const useWorkspace = defineStore('workspace', () => {
  const tabs = ref<WorkspaceTab[]>([])
  const activeId = ref<string | null>(null)

  const active = computed(() => tabs.value.find(t => t.id === activeId.value) ?? null)

  function openTab(tab: Omit<WorkspaceTab, 'id'> & { id?: string }): string {
    // 相同 目标（类型+连接+库+表）已存在则聚焦
    if (tab.type !== 'sql') {
      const dup = tabs.value.find(
        t => t.type === tab.type && t.connId === tab.connId
          && t.database === tab.database && t.table === tab.table,
      )
      if (dup) {
        activeId.value = dup.id
        return dup.id
      }
    }
    const id = tab.id ?? tabId()
    tabs.value.push({ ...tab, id } as WorkspaceTab)
    activeId.value = id
    return id
  }

  function newSqlTab(connId: string | null, database: string | null, sql = ''): string {
    return openTab({ type: 'sql', title: '未命名查询', connId, database, table: null, sql })
  }

  function closeTab(id: string) {
    const idx = tabs.value.findIndex(t => t.id === id)
    if (idx < 0) return
    tabs.value.splice(idx, 1)
    if (activeId.value === id) {
      const next = tabs.value[Math.min(idx, tabs.value.length - 1)]
      activeId.value = next?.id ?? null
    }
  }

  function renameTab(id: string, title: string) {
    const t = tabs.value.find(x => x.id === id)
    if (t) t.title = title
  }

  function onConnectionLost() {
    // 断开连接时关闭该连接的所有标签
    tabs.value = tabs.value.filter(t => !t.connId)
    activeId.value = tabs.value[0]?.id ?? null
  }

  return { tabs, activeId, active, openTab, newSqlTab, closeTab, renameTab, onConnectionLost }
})
