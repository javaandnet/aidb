<script setup lang="ts">
// SQL 标签：CodeMirror 6 编辑器 + 多结果面板 + 导出
import { onMounted, onBeforeUnmount, ref, shallowRef } from 'vue'
import { save as saveDialog } from '@tauri-apps/plugin-dialog'
import { EditorView, keymap } from '@codemirror/view'
import { EditorState } from '@codemirror/state'
import { basicSetup } from 'codemirror'
import { sql } from '@codemirror/lang-sql'
import { oneDark } from '@codemirror/theme-one-dark'
import { api } from '../api'
import { useConnStore } from '../stores/connections'
import type { WorkspaceTab } from '../stores/workspace'
import type { QueryResult } from '../types'
import ResultGrid from './ResultGrid.vue'

const props = defineProps<{ tab: WorkspaceTab }>()
const conn = useConnStore()

const mountEl = ref<HTMLElement | null>(null)
const view = shallowRef<EditorView | null>(null)
const results = ref<QueryResult[]>([])
const activeResult = ref(0)
const running = ref(false)
const error = ref('')
const splitH = ref(55) // 编辑器高度百分比

/** 构建 schema 补全：表名 + 各表列名（最多取 60 表，避免过慢） */
type SqlSchema = { [table: string]: string[] }
async function buildSchema(): Promise<SqlSchema> {
  const schema: SqlSchema = {}
  for (const t of conn.tables.slice(0, 60)) {
    try {
      const cols = await conn.columnsOf(t.name)
      schema[t.name] = cols.map(c => c.name)
    } catch { /* 忽略单表失败 */ }
  }
  return schema
}

async function createEditor() {
  const schema = props.tab.connId ? await buildSchema() : {}
  const startState = EditorState.create({
    doc: props.tab.sql ?? initialSql(),
    extensions: [
      basicSetup,
      oneDark,
      sql({ schema, upperCaseKeywords: true }),
      keymap.of([
        { key: 'Mod-Enter', run: () => { run(); return true } },
        { key: 'Mod-s', run: () => { saveText(); return true } },
      ]),
      EditorView.theme({
        '&': { height: '100%', fontSize: '13px' },
        '.cm-scroller': { overflow: 'auto', fontFamily: 'var(--font-mono)' },
      }),
    ],
  })
  view.value = new EditorView({ state: startState, parent: mountEl.value! })
}

function initialSql(): string {
  if (conn.kind === 'mysql') return '-- MySQL\nSELECT * FROM `表名` LIMIT 100;\n'
  return "-- SQLite\nSELECT * FROM \"表名\" LIMIT 100;\n"
}

function currentText(): string {
  const v = view.value
  if (!v) return ''
  const sel = v.state.selection.main
  if (!sel.empty) return v.state.sliceDoc(sel.from, sel.to)
  return v.state.doc.toString()
}

function saveText() {
  props.tab.sql = currentText()
}

async function run() {
  if (!props.tab.connId) { error.value = '未连接数据库'; return }
  const text = currentText()
  if (!text.trim()) return
  running.value = true
  error.value = ''
  saveText()
  try {
    results.value = await api.executeSql(props.tab.connId, text)
    activeResult.value = 0
  } catch (e: any) {
    error.value = typeof e === 'string' ? e : e?.message ?? JSON.stringify(e)
    results.value = []
  } finally {
    running.value = false
  }
}

async function exportResult(format: 'csv' | 'json') {
  const r = results.value[activeResult.value]
  if (!r || !props.tab.connId) return
  const path = await saveDialog({
    defaultPath: `query-result.${format}`,
    filters: [{ name: format.toUpperCase(), extensions: [format] }],
  })
  if (!path) return
  // 直接写前端已有数据：走 table/sql 通道会重新执行，这里用原 SQL + 单语句导出
  try {
    await api.exportResult(props.tab.connId, props.tab.database, {
      sql: r.statement, path, format,
    })
    alert(`已导出到 ${path}`)
  } catch (e: any) {
    error.value = String(typeof e === 'string' ? e : e)
  }
}

function onResize(e: PointerEvent) {
  const host = (e.currentTarget as HTMLElement).parentElement
  if (!host) return
  const rect = host.getBoundingClientRect()
  splitH.value = Math.min(85, Math.max(15, ((e.clientY - rect.top) / rect.height) * 100))
  e.preventDefault()
}

// 窗口级 ⌘↵ 兜底：编辑器无 DOM 焦点时也能执行（已被 CodeMirror keymap 处理时 defaultPrevented，不重复触发）
function onGlobalKey(e: KeyboardEvent) {
  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !e.defaultPrevented && !running.value) {
    e.preventDefault()
    run()
  }
}

onMounted(async () => {
  await createEditor()
  window.addEventListener('keydown', onGlobalKey)
})
onBeforeUnmount(() => {
  saveText()
  window.removeEventListener('keydown', onGlobalKey)
  view.value?.destroy()
})
</script>

<template>
  <div class="sql-tab">
    <div class="sql-toolbar">
      <button class="primary" :disabled="running || !tab.connId" @click="run">
        {{ running ? '执行中…' : '执行 ⌘↵' }}
      </button>
      <span class="hint">选中部分文字可只执行选中语句</span>
      <span class="spacer"></span>
      <template v-if="results.length">
        <span class="res-tabs">
          <button
            v-for="(r, i) in results"
            :key="i"
            :class="{ on: i === activeResult }"
            @click="activeResult = i"
            :title="r.statement"
          >结果 {{ i + 1 }}<template v-if="!r.isQuery">（{{ r.affectedRows }}）</template></button>
        </span>
        <button @click="exportResult('csv')" :disabled="!results[activeResult]?.isQuery">导出结果CSV</button>
        <button @click="exportResult('json')" :disabled="!results[activeResult]?.isQuery">JSON</button>
      </template>
    </div>

    <div class="editor-host" :style="{ height: splitH + '%' }">
      <div ref="mountEl" class="cm-mount"></div>
    </div>
    <div class="splitter" @pointerdown.prevent="onResize"></div>

    <div class="result-host">
      <p v-if="error" class="error-text pad">{{ error }}</p>
      <p v-else-if="!results.length" class="hint pad">尚未执行。⌘↵ 运行当前语句（或选中片段运行）</p>
      <ResultGrid v-else :key="activeResult" :result="results[activeResult]" />
    </div>
  </div>
</template>

<style scoped>
.sql-tab { display: flex; flex-direction: column; flex: 1; min-height: 0; }
.sql-toolbar {
  display: flex; align-items: center; gap: 8px;
  padding: 6px 10px;
  border-bottom: 1px solid var(--border);
  background: var(--bg-panel);
  flex-shrink: 0;
}
.spacer { flex: 1; }
.res-tabs { display: flex; gap: 2px; }
.res-tabs button { border-radius: 4px; padding: 3px 8px; max-width: 140px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.res-tabs button.on { background: var(--bg-selected); }
.editor-host { min-height: 60px; overflow: hidden; }
.cm-mount { height: 100%; }
.splitter { height: 5px; cursor: row-resize; background: var(--border); flex-shrink: 0; }
.splitter:hover { background: var(--accent); }
.result-host { flex: 1; min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
.pad { padding: 14px; user-select: text; }
</style>
