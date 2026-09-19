<script setup lang="ts">
// 左侧库表树：MySQL 两层（库 -> 表），SQLite 一层（表）
import { ref, computed } from 'vue'
import { useConnStore } from '../stores/connections'
import { useWorkspace } from '../stores/workspace'

const conn = useConnStore()
const ws = useWorkspace()

const search = ref('')
const expandedDb = ref<string | null>(null)

const filteredTables = computed(() => {
  const q = search.value.trim().toLowerCase()
  if (!q) return conn.tables
  return conn.tables.filter(t => t.name.toLowerCase().includes(q))
})

function openTable(t: { name: string; schema: string; kind: string }) {
  ws.openTab({
    type: 'data',
    title: t.name,
    connId: conn.connectedId,
    database: conn.kind === 'mysql' ? t.schema : null,
    table: t.name,
  })
}

function openStructure(t: { name: string; schema: string }) {
  ws.openTab({
    type: 'structure',
    title: `结构 · ${t.name}`,
    connId: conn.connectedId,
    database: conn.kind === 'mysql' ? t.schema : null,
    table: t.name,
  })
}

function pickDb(db: string) {
  expandedDb.value = db
  conn.useDatabase(db)
}
</script>

<template>
  <aside class="sidebar">
    <div class="search-box">
      <input v-model="search" placeholder="过滤表名…" :disabled="!conn.connectedId" />
    </div>
    <div class="tree">
      <p v-if="!conn.connectedId" class="hint empty">未连接数据库<br />点击左上角「选择连接…」</p>
      <template v-else>
        <!-- MySQL：先选库 -->
        <template v-if="conn.kind === 'mysql' && !conn.currentDb">
          <div class="node db" v-for="d in conn.databases" :key="d" @click="pickDb(d)">
            🗀 {{ d }}
          </div>
        </template>
        <template v-else>
          <div class="node group" title="已隐藏 sqlite_* 等内部表">表 ({{ filteredTables.length }})</div>
          <div
            v-for="t in filteredTables"
            :key="t.schema + '.' + t.name"
            class="node table"
            :title="t.name"
            @click="openTable(t)"
            @dblclick="openStructure(t)"
          >
            <span class="ico">{{ t.kind === 'view' ? '👁' : '▤' }}</span>
            <span class="tname">{{ t.name }}</span>
            <span class="tact" @click.stop="openStructure(t)">结构</span>
          </div>
        </template>
      </template>
    </div>
    <div class="side-foot">
      <button class="hist-btn" :disabled="!conn.connectedId" @click="ws.openTab({ type: 'history', title: '历史', connId: conn.connectedId, database: null, table: null })">
        查询历史
      </button>
    </div>
  </aside>
</template>

<style scoped>
.sidebar {
  width: 240px;
  flex-shrink: 0;
  background: var(--bg-panel);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
}
.search-box { padding: 8px; border-bottom: 1px solid var(--border); }
.search-box input { width: 100%; }
.tree { flex: 1; overflow: auto; padding: 6px 0; }
.node {
  padding: 4px 12px;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 6px;
  white-space: nowrap;
}
.node:hover { background: var(--bg-hover); }
.node.group { color: var(--text-dim); font-size: 11px; text-transform: uppercase; cursor: default; }
.node.db { font-weight: 600; }
.tname { overflow: hidden; text-overflow: ellipsis; flex: 1; }
.tact { color: var(--accent); font-size: 11px; opacity: 0; }
.node:hover .tact { opacity: 1; }
.ico { width: 16px; text-align: center; }
.empty { text-align: center; margin-top: 40px; line-height: 2; }
.side-foot { border-top: 1px solid var(--border); padding: 8px; }
.hist-btn { width: 100%; }
</style>
