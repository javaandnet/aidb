<script setup lang="ts">
import { useWorkspace } from '../stores/workspace'

const ws = useWorkspace()
</script>

<template>
  <div class="tabstrip" v-if="ws.tabs.length">
    <div
      v-for="t in ws.tabs"
      :key="t.id"
      class="tab"
      :class="{ active: t.id === ws.activeId }"
      @click="ws.activeId = t.id"
    >
      <span class="kind">{{ t.type === 'data' ? '▤' : t.type === 'sql' ? '⟩' : t.type === 'structure' ? '⚙' : '🕘' }}</span>
      <span class="title">{{ t.title }}</span>
      <span class="close" @click.stop="ws.closeTab(t.id)">×</span>
    </div>
  </div>
</template>

<style scoped>
.tabstrip {
  display: flex;
  background: var(--bg-panel);
  border-bottom: 1px solid var(--border);
  overflow-x: auto;
  flex-shrink: 0;
}
.tab {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 7px 10px 7px 14px;
  border-right: 1px solid var(--border);
  cursor: pointer;
  color: var(--text-dim);
  max-width: 200px;
  white-space: nowrap;
}
.tab:hover { background: var(--bg-hover); }
.tab.active { background: var(--bg); color: var(--text); box-shadow: inset 0 2px 0 var(--accent); }
.title { overflow: hidden; text-overflow: ellipsis; }
.close { padding: 0 4px; border-radius: 4px; }
.close:hover { background: var(--border); }
.kind { font-size: 11px; }
</style>
