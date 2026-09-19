<script setup lang="ts">
// 查询历史：列表 + 复制到新 SQL 标签 + 清空
import { onMounted, ref } from 'vue'
import { api } from '../api'
import { useWorkspace } from '../stores/workspace'
import { useConnStore } from '../stores/connections'
import type { WorkspaceTab } from '../stores/workspace'
import type { HistoryEntry } from '../types'

const props = defineProps<{ tab: WorkspaceTab }>()
const ws = useWorkspace()
const conn = useConnStore()

const entries = ref<HistoryEntry[]>([])
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    entries.value = await api.listHistory(300)
  } finally {
    loading.value = false
  }
}

function fmtTs(ts: number): string {
  return new Date(ts).toLocaleString()
}

function reuse(e: HistoryEntry) {
  ws.newSqlTab(conn.connectedId, conn.currentDb, e.sql)
}

async function clearAll() {
  if (!confirm('清空全部查询历史？')) return
  await api.clearHistory()
  await load()
}

onMounted(load)
</script>

<template>
  <div class="history-tab">
    <div class="h-toolbar">
      <button @click="load">刷新</button>
      <span class="spacer"></span>
      <button class="danger" @click="clearAll">清空历史</button>
    </div>
    <div class="h-list">
      <p v-if="loading" class="hint pad">加载中…</p>
      <div v-for="e in entries" :key="e.id" class="h-item">
        <div class="h-meta hint">
          <span>{{ fmtTs(e.createdAt) }}</span>
          <span v-if="e.durationMs != null"> · {{ e.durationMs }}ms</span>
          <span v-if="e.rowCount != null"> · {{ e.rowCount }} 行</span>
          <span v-if="e.error" class="fail"> · 失败</span>
        </div>
        <pre class="h-sql mono" :title="e.sql">{{ e.sql }}</pre>
        <div class="h-ops">
          <button @click="reuse(e)">复制到新查询</button>
        </div>
      </div>
      <p v-if="!loading && !entries.length" class="hint pad">暂无历史</p>
    </div>
  </div>
</template>

<style scoped>
.history-tab { display: flex; flex-direction: column; flex: 1; min-height: 0; }
.h-toolbar { display: flex; gap: 8px; padding: 8px 10px; border-bottom: 1px solid var(--border); background: var(--bg-panel); }
.spacer { flex: 1; }
.h-list { flex: 1; overflow: auto; }
.h-item { border-bottom: 1px solid var(--border); padding: 8px 12px; display: flex; align-items: flex-start; gap: 12px; }
.h-item:hover { background: var(--bg-hover); }
.h-meta { flex-shrink: 0; width: 190px; }
.h-meta .fail { color: var(--red); }
.h-sql {
  flex: 1; white-space: pre-wrap; word-break: break-all;
  font-size: 12px; max-height: 66px; overflow: hidden; user-select: text;
}
.h-ops { flex-shrink: 0; }
.pad { padding: 14px; }
</style>
