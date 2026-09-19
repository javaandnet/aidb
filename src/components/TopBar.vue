<script setup lang="ts">
import { useConnStore } from '../stores/connections'
import { useWorkspace } from '../stores/workspace'

const emit = defineEmits<{ (e: 'openConnections'): void }>()
const conn = useConnStore()
const ws = useWorkspace()

function onDbChange(e: Event) {
  const v = (e.target as HTMLSelectElement).value
  if (v) conn.useDatabase(v)
}

async function refresh() {
  await conn.loadProfiles()
  await conn.refreshTree()
}
</script>

<template>
  <header class="topbar">
    <div class="left">
      <button class="conn-btn" @click="emit('openConnections')">
        <span class="dot" :class="{ on: !!conn.connectedId }"></span>
        {{ conn.connected ? conn.connected.name : '选择连接…' }}
      </button>
      <select
        v-if="conn.connectedId && conn.kind === 'mysql'"
        class="db-select"
        :value="conn.currentDb ?? ''"
        @change="onDbChange"
      >
        <option disabled value="">选择数据库…</option>
        <option v-for="d in conn.databases" :key="d" :value="d">{{ d }}</option>
      </select>
      <span v-else-if="conn.connectedId" class="badge">main</span>
      <button :disabled="!conn.connectedId" @click="refresh" title="刷新结构">⟳</button>
    </div>
    <div class="right">
      <button
        class="primary"
        :disabled="!conn.connectedId"
        @click="ws.newSqlTab(conn.connectedId, conn.currentDb)"
      >+ 查询</button>
    </div>
  </header>
</template>

<style scoped>
.topbar {
  height: 44px;
  flex-shrink: 0;
  background: var(--bg-header);
  border-bottom: 1px solid var(--border);
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 12px;
  gap: 10px;
}
.left, .right { display: flex; align-items: center; gap: 8px; }
.conn-btn { font-weight: 600; max-width: 260px; overflow: hidden; }
.dot {
  display: inline-block; width: 8px; height: 8px; border-radius: 50%;
  background: var(--text-dim); margin-right: 6px;
}
.dot.on { background: var(--green); }
.db-select { max-width: 200px; }
</style>
