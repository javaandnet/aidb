<script setup lang="ts">
// 只读结果网格（SQL 标签下方；超过 2000 行仅渲染前 2000）
import { computed } from 'vue'
import type { QueryResult } from '../types'

const props = defineProps<{ result: QueryResult }>()

const LIMIT = 2000
const shown = computed(() => props.result.rows.slice(0, LIMIT))
const truncated = computed(() => props.result.rows.length > LIMIT)

function display(v: any): string {
  if (v === null || v === undefined) return 'NULL'
  if (typeof v === 'object') return JSON.stringify(v)
  return String(v)
}
</script>

<template>
  <div class="result-grid">
    <div v-if="!result.isQuery" class="hint dml">
      影响行数：{{ result.affectedRows }} · 耗时 {{ result.elapsedMs }}ms
    </div>
    <template v-else>
      <div class="table-wrap">
        <table class="grid-table">
          <thead>
            <tr>
              <th class="rownum">#</th>
              <th v-for="c in result.columns" :key="c" :title="c">{{ c }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(row, i) in shown" :key="i">
              <td class="rownum">{{ i + 1 }}</td>
              <td
                v-for="(cell, j) in row"
                :key="j"
                :class="{ nullv: cell === null || cell === undefined, blobv: result.blobColumns.includes(j) }"
                :title="display(cell)"
              >{{ display(cell) }}</td>
            </tr>
          </tbody>
        </table>
        <p v-if="truncated" class="hint more">仅显示前 {{ LIMIT }} 行（共 {{ result.rows.length }} 行），完整数据请用导出</p>
      </div>
      <div class="foot hint">
        {{ result.rows.length }} 行 · {{ result.elapsedMs }}ms
      </div>
    </template>
  </div>
</template>

<style scoped>
.result-grid { display: flex; flex-direction: column; height: 100%; min-height: 0; }
.table-wrap { flex: 1; overflow: auto; }
.rownum { color: var(--text-dim); text-align: right; width: 48px; }
.nullv { color: var(--text-dim); font-style: italic; }
.blobv { color: var(--text-dim); }
.dml { padding: 16px; }
.foot { padding: 4px 10px; border-top: 1px solid var(--border); flex-shrink: 0; }
.more { padding: 8px; }
</style>
