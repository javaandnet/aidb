<script setup lang="ts">
import { useWorkspace } from '../stores/workspace'
import DataTab from './DataTab.vue'
import SqlTab from './SqlTab.vue'
import StructureTab from './StructureTab.vue'
import HistoryTab from './HistoryTab.vue'

const ws = useWorkspace()
</script>

<template>
  <div class="tab-body">
    <p v-if="!ws.active" class="placeholder">
      <span class="big">aidb</span><br />
      选择连接后，从左侧点击表浏览数据，或按 <kbd>⌘N</kbd> 新建查询
    </p>
    <template v-else>
      <DataTab v-if="ws.active.type === 'data'" :key="ws.active.id" :tab="ws.active" />
      <SqlTab v-else-if="ws.active.type === 'sql'" :key="ws.active.id" :tab="ws.active" />
      <StructureTab v-else-if="ws.active.type === 'structure'" :key="ws.active.id" :tab="ws.active" />
      <HistoryTab v-else-if="ws.active.type === 'history'" :key="ws.active.id" :tab="ws.active" />
    </template>
  </div>
</template>

<style scoped>
.tab-body { flex: 1; min-height: 0; display: flex; flex-direction: column; position: relative; }
.placeholder {
  margin: auto;
  color: var(--text-dim);
  text-align: center;
  line-height: 2.2;
}
.placeholder .big { font-size: 40px; font-weight: 200; letter-spacing: 6px; color: var(--border); }
kbd {
  background: var(--bg-header);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 1px 6px;
  font-size: 11px;
}
</style>
