<script setup lang="ts">
// 数据网格：虚拟滚动浏览、排序、WHERE 筛选、单元格编辑回写、增删行、导出
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { save as saveDialog } from '@tauri-apps/plugin-dialog'
import { api } from '../api'
import { useConnStore } from '../stores/connections'
import type { WorkspaceTab } from '../stores/workspace'
import type { ColumnInfo, PageResult } from '../types'
import ImportWizard from './ImportWizard.vue'

const props = defineProps<{ tab: WorkspaceTab }>()
const conn = useConnStore()

const ROW_H = 28
const PAGE_SIZES = [50, 100, 500, 1000]

const columns = ref<ColumnInfo[]>([])
const page = ref<PageResult | null>(null)
const loading = ref(false)
const error = ref('')
const pageSize = ref(50)
const offset = ref(0)
const whereSql = ref('')
const whereApplied = ref<string | null>(null)
const orderCol = ref<string | null>(null)
const orderDir = ref<'ASC' | 'DESC'>('ASC')

// 编辑状态
const edits = reactive(new Map<string, any>()) // `${rowIdx}:${colName}` -> 新值(含 null)
const newRows = ref<Record<string, any>[]>([])
const deletedIdx = ref(new Set<number>())
const editingCell = ref<{ r: number; c: string } | null>(null)
const editBuffer = ref('')
// 选中行（viewRows 下标），行内任意点击选中整行
const selectedRow = ref<number | null>(null)

// 虚拟滚动
const scrollTop = ref(0)
const viewportH = ref(600)
const scrollEl = ref<HTMLElement | null>(null)

const showImport = ref(false)

const pkCols = computed(() => columns.value.filter(c => c.pkPos != null))
const editable = computed(() => pkCols.value.length > 0)
const colNames = computed(() => columns.value.map(c => c.name))
const gridStyle = computed(() => ({
  gridTemplateColumns: `44px ${colNames.value.map(() => 'minmax(140px, 220px)').join(' ')} 120px`,
}))

const totalRows = computed(() =>
  (page.value?.total ?? 0) + newRows.value.length - deletedIdx.value.size,
)

// 合并视图行：数据页 + 新增行
interface ViewRow {
  kind: 'data' | 'new'
  idx: number // 在原数组中的下标
  cells: any[] // 长度 = 列数（新行为 undefined 填充）
  deleted: boolean
}
const viewRows = computed<ViewRow[]>(() => {
  const out: ViewRow[] = []
  const rows = page.value?.rows ?? []
  for (let i = 0; i < rows.length; i++) {
    out.push({ kind: 'data', idx: i, cells: rows[i], deleted: deletedIdx.value.has(i) })
  }
  newRows.value.forEach((obj, j) => {
    out.push({
      kind: 'new', idx: j,
      cells: colNames.value.map(n => obj[n]),
      deleted: false,
    })
  })
  return out
})

// 窗口化
const startIdx = computed(() => Math.max(0, Math.floor(scrollTop.value / ROW_H) - 5))
const visibleCount = computed(() => Math.ceil(viewportH.value / ROW_H) + 12)
const winRows = computed(() => viewRows.value.slice(startIdx.value, startIdx.value + visibleCount.value))
const padTop = computed(() => startIdx.value * ROW_H)
const padBottom = computed(() =>
  Math.max(0, (viewRows.value.length - startIdx.value - winRows.value.length) * ROW_H),
)

function onScroll() {
  if (scrollEl.value) scrollTop.value = scrollEl.value.scrollTop
}

function cellValue(r: number, col: string): any {
  const key = `${r}:${col}`
  if (edits.has(key)) return edits.get(key)
  return viewRows.value[r]?.cells[colNames.value.indexOf(col)]
}

function isDirty(r: number, col: string): boolean {
  return edits.has(`${r}:${col}`)
}

function display(v: any): string {
  if (v === null || v === undefined) return 'NULL'
  if (typeof v === 'object') return JSON.stringify(v)
  return String(v)
}

function startEdit(r: number, col: string) {
  if (!editable.value) return
  // 已在编辑该格时忽略（避免点击 input 冒泡重置输入）
  if (editingCell.value && editingCell.value.r === r && editingCell.value.c === col) return
  const v = cellValue(r, col)
  editingCell.value = { r, c: col }
  editBuffer.value = v === null || v === undefined ? '' : String(v)
}

function onCellClick(r: number, col: string) {
  selectedRow.value = r
  startEdit(r, col)
}

function commitEdit() {
  if (!editingCell.value) return
  const { r, c } = editingCell.value
  const row = viewRows.value[r]
  if (row?.kind === 'new') {
    newRows.value[row.idx][c] = parseInput(editBuffer.value)
  } else {
    const original = cellValue(r, c)
    const parsed = parseInput(editBuffer.value)
    const key = `${r}:${c}`
    if (String(original) === String(parsed) && typeof original === typeof parsed) edits.delete(key)
    else edits.set(key, parsed)
  }
  editingCell.value = null
}

function parseInput(s: string): any {
  // 字面量 \N 或 NULL(不区分大小写，配合引号规则)：输入 null 视为 NULL
  if (s === '\\N') return null
  return s
}

function addRow() {
  if (!editable.value) return
  newRows.value.push({})
}

/// 复制选中行：跳过单列整型主键（让库自增），仅复制原始值
function duplicateRow() {
  if (selectedRow.value === null || !editable.value) return
  const row = viewRows.value[selectedRow.value]
  if (!row) return
  const obj: Record<string, any> = {}
  columns.value.forEach((c: ColumnInfo) => {
    const skipPk = pkCols.value.length === 1 && c.pkPos != null && /int/i.test(c.dataType)
    if (skipPk) return
    const v = cellValue(selectedRow.value!, c.name)
    if (v === null || v === undefined) return
    if (typeof v === 'object') return // blob/JSON 不复制
    obj[c.name] = v
  })
  newRows.value.push(obj)
}

function markDelete(r: number) {
  const row = viewRows.value[r]
  if (!row) return
  if (row.kind === 'new') {
    newRows.value.splice(row.idx, 1)
    if (selectedRow.value === r) selectedRow.value = null
  } else {
    if (deletedIdx.value.has(row.idx)) deletedIdx.value.delete(row.idx)
    else deletedIdx.value.add(row.idx)
  }
}

function pkPairs(r: number): [string, any][] {
  const row = viewRows.value[r]
  return pkCols.value.map(c => {
    const key = `${r}:${c.name}`
    const v = edits.has(key) ? edits.get(key) : row.cells[colNames.value.indexOf(c.name)]
    return [c.name, coerce(v)] as [string, any]
  })
}

function coerce(v: any): any {
  if (typeof v === 'string' && /^-?\d+$/.test(v)) {
    const n = Number(v)
    if (Number.isSafeInteger(n)) return n
  }
  return v
}

async function load() {
  if (!props.tab.connId || !props.tab.table) return
  loading.value = true
  error.value = ''
  selectedRow.value = null
  editingCell.value = null
  try {
    columns.value = await conn.columnsOf(props.tab.table)
    page.value = await api.queryTable(props.tab.connId, props.tab.database, props.tab.table, {
      whereSql: whereApplied.value,
      orderCol: orderCol.value,
      orderDir: orderCol.value ? orderDir.value : null,
      limit: pageSize.value,
      offset: offset.value,
    })
  } catch (e: any) {
    error.value = typeof e === 'string' ? e : e?.message ?? JSON.stringify(e)
    page.value = null
  } finally {
    loading.value = false
  }
  if (scrollEl.value) { scrollEl.value.scrollTop = 0; scrollTop.value = 0 }
}

function applyWhere() {
  if (!confirmIfDirty()) return
  whereApplied.value = whereSql.value.trim() || null
  offset.value = 0
  discardEdits()
  load()
}

function sortBy(col: string) {
  if (orderCol.value === col) orderDir.value = orderDir.value === 'ASC' ? 'DESC' : 'ASC'
  else { orderCol.value = col; orderDir.value = 'ASC' }
  load()
}

function confirmIfDirty(): boolean {
  if (!dirtyCount.value) return true
  return confirm('有未保存的修改，翻页/重查会丢失这些修改，继续？')
}

function turn(delta: number) {
  if (!confirmIfDirty()) return
  const next = offset.value + delta * pageSize.value
  if (next < 0 || next >= (page.value?.total ?? 0)) return
  discardEdits()
  offset.value = next
  load()
}

function discardEdits() {
  edits.clear()
  newRows.value = []
  deletedIdx.value = new Set()
  editingCell.value = null
  selectedRow.value = null
}

const dirtyCount = computed(() => edits.size + newRows.value.length + deletedIdx.value.size)

async function saveChanges() {
  if (!dirtyCount.value || !props.tab.connId || !props.tab.table) return
  const updates: { pk: [string, any][]; set: [string, any][] }[] = []
  const byRow = new Map<number, [string, any][]>()
  for (const [key, val] of edits.entries()) {
    const [rStr, col] = key.split(/:(.*)/)
    const r = Number(rStr)
    if (!byRow.has(r)) byRow.set(r, [])
    byRow.get(r)!.push([col, coerce(val)])
  }
  for (const [r, set] of byRow.entries()) {
    if (deletedIdx.value.has(r)) continue
    updates.push({ pk: pkPairs(r), set })
  }
  const inserts = newRows.value.map(obj =>
    Object.entries(obj)
      .filter(([, v]) => v !== undefined)
      .map(([k, v]) => [k, coerce(v)] as [string, any]),
  ).filter(r => r.length > 0)
  const deletes: [string, any][][] = []
  for (const i of deletedIdx.value) {
    const srcRow = (page.value?.rows ?? [])[i]
    if (!srcRow) continue
    deletes.push(
      pkCols.value.map(c => [c.name, coerce(srcRow[colNames.value.indexOf(c.name)])] as [string, any]),
    )
  }
  try {
    await api.applyChanges(props.tab.connId, props.tab.database, props.tab.table, {
      updates, inserts, deletes,
    })
    discardEdits()
    await load()
  } catch (e: any) {
    error.value = typeof e === 'string' ? e : e?.message ?? JSON.stringify(e)
  }
}

async function exportAs(format: 'csv' | 'json') {
  if (!props.tab.connId || !props.tab.table) return
  const name = props.tab.table
  const path = await saveDialog({
    defaultPath: `${name}.${format}`,
    filters: [{ name: format.toUpperCase(), extensions: [format] }],
  })
  if (!path) return
  try {
    const done = await api.exportResult(props.tab.connId, props.tab.database, {
      table: name, path, format,
    })
    alert(`已导出 ${done.rows} 行到 ${done.path}`)
  } catch (e: any) {
    error.value = String(typeof e === 'string' ? e : e)
  }
}

function onKeydown(e: KeyboardEvent) {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
    e.preventDefault()
    saveChanges()
    return
  }
  // Delete 键删除/恢复选中行（编辑中或焦点在输入框时不拦截）
  if (e.key === 'Delete' && selectedRow.value !== null && !editingCell.value && editable.value) {
    const t = e.target as HTMLElement | null
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return
    e.preventDefault()
    markDelete(selectedRow.value)
  }
}

watch(() => (props.tab.connId ?? '') + '|' + (props.tab.table ?? ''), () => { discardEdits(); load() })
onMounted(() => {
  load()
  window.addEventListener('keydown', onKeydown)
  if (scrollEl.value) viewportH.value = scrollEl.value.clientHeight
})
onUnmounted(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <div class="data-tab">
    <div class="toolbar">
      <input
        v-model="whereSql"
        class="where mono"
        placeholder="WHERE 条件，例如：id > 10 AND name LIKE '%abc%'（回车应用）"
        @keyup.enter="applyWhere"
      />
      <select v-model.number="pageSize" @change="offset = 0; discardEdits(); load()">
        <option v-for="s in PAGE_SIZES" :key="s" :value="s">{{ s }} 行/页</option>
      </select>
      <div class="pager">
        <button @click="turn(-1)">‹</button>
        <span class="hint">{{ totalRows ? (offset + 1) : 0 }}–{{ Math.min(offset + pageSize, page?.total ?? 0) }} / {{ totalRows }}</span>
        <button @click="turn(1)">›</button>
      </div>
      <span class="spacer"></span>
      <span v-if="dirtyCount" class="dirty">{{ dirtyCount }} 处未保存</span>
      <button :disabled="!editable || !dirtyCount" @click="discardEdits">放弃</button>
      <button class="primary" :disabled="!dirtyCount" @click="saveChanges">保存 ⌘S</button>
      <span class="vsep"></span>
      <button :disabled="!editable" @click="addRow">+ 行</button>
      <button :disabled="!editable || selectedRow === null" @click="duplicateRow" title="复制选中行为新增行">复制行</button>
      <button
        class="danger"
        :disabled="selectedRow === null"
        @click="selectedRow !== null && markDelete(selectedRow)"
      >{{ selectedRow !== null && viewRows[selectedRow]?.deleted ? '恢复选中行' : '删除选中行' }}</button>
      <button @click="showImport = true" :disabled="!editable">导入…</button>
      <button :disabled="!page" @click="exportAs('csv')">导出CSV</button>
      <button :disabled="!page" @click="exportAs('json')">导出JSON</button>
    </div>

    <p v-if="error" class="error-text banner">{{ error }}</p>
    <p v-if="!editable && columns.length" class="hint banner">该表没有主键，只读模式</p>

    <div ref="scrollEl" class="grid-scroll" @scroll="onScroll">
      <div class="grid" :style="gridStyle">
        <div class="gcell head rownum">#</div>
        <div
          v-for="c in columns"
          :key="c.name"
          class="gcell head"
          :title="c.dataType + (c.pkPos ? ' PK' : '')"
          @click="sortBy(c.name)"
        >
          <span :class="{ pk: c.pkPos != null }">{{ c.name }}</span>
          <span class="dtype">{{ c.dataType }}</span>
          <span v-if="orderCol === c.name" class="oinfo">{{ orderDir === 'ASC' ? '↑' : '↓' }}</span>
        </div>
        <div class="gcell head">操作</div>

        <div class="padrow" :style="{ height: padTop + 'px' }"></div>
        <div v-for="(row, wi) in winRows" :key="startIdx + wi" class="grow">
          <div
            :key="'rn' + (startIdx + wi)"
            class="gcell rownum"
            :class="{ del: row.deleted, new: row.kind === 'new', sel: selectedRow === startIdx + wi }"
            @click="selectedRow = startIdx + wi"
          >{{ row.kind === 'new' ? '+' : startIdx + wi + 1 + offset }}</div>
          <div
            v-for="c in columns"
            :key="(startIdx + wi) + '.' + c.name"
            class="gcell"
            :class="{
              nullv: cellValue(startIdx + wi, c.name) === null || cellValue(startIdx + wi, c.name) === undefined,
              dirty: isDirty(startIdx + wi, c.name),
              deleted: row.deleted,
              sel: selectedRow === startIdx + wi,
              blob: page?.blobColumns?.includes(colNames.indexOf(c.name)),
            }"
            @click="onCellClick(startIdx + wi, c.name)"
          >
            <template v-if="editingCell && editingCell.r === startIdx + wi && editingCell.c === c.name">
              <input
                v-model="editBuffer"
                autofocus
                class="cell-input"
                @keyup.enter="commitEdit()"
                @keyup.esc="editingCell = null"
                @blur="commitEdit()"
              />
            </template>
            <template v-else>{{ display(cellValue(startIdx + wi, c.name)) }}</template>
          </div>
          <div class="gcell ops" :class="{ sel: selectedRow === startIdx + wi }">
            <button class="mini danger" @click="markDelete(startIdx + wi)">
              {{ row.deleted ? '恢复' : '删除' }}
            </button>
          </div>
        </div>
        <div class="padrow" :style="{ height: padBottom + 'px' }"></div>
      </div>
      <p v-if="loading" class="loading hint">加载中…</p>
    </div>

    <ImportWizard
      v-if="showImport && tab.connId && tab.table"
      :conn-id="tab.connId"
      :database="tab.database"
      :table="tab.table"
      :columns="columns"
      @close="showImport = false"
      @done="load()"
    />
  </div>
</template>

<style scoped>
.data-tab { display: flex; flex-direction: column; flex: 1; min-height: 0; }
.toolbar {
  display: flex; align-items: center; gap: 8px;
  padding: 8px 10px;
  border-bottom: 1px solid var(--border);
  background: var(--bg-panel);
  flex-shrink: 0;
}
.where { flex: 1; min-width: 180px; }
.pager { display: flex; align-items: center; gap: 6px; }
.pager button { padding: 3px 9px; }
.spacer { flex: 1; }
.vsep { width: 1px; height: 18px; background: var(--border); }
.dirty { color: var(--yellow); font-size: 12px; }
.banner { padding: 5px 12px; border-bottom: 1px solid var(--border); background: var(--bg-panel); }
.error-text.banner { color: var(--red); user-select: text; }

.grid-scroll { flex: 1; overflow: auto; position: relative; }
.grid { display: grid; min-width: max-content; }
.gcell {
  height: var(--row-h);
  line-height: calc(var(--row-h) - 1px);
  border-right: 1px solid var(--border);
  border-bottom: 1px solid var(--border);
  padding: 0 8px;
  font-family: var(--font-mono);
  font-size: 12px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  background: var(--bg);
}
.gcell.head {
  position: sticky; top: 0; z-index: 3;
  background: var(--bg-header);
  font-family: -apple-system, sans-serif;
  font-weight: 600;
}
.gcell.head .pk { color: var(--yellow); }
.dtype { color: var(--text-dim); font-size: 10px; margin-left: 6px; }
.oinfo { margin-left: 4px; color: var(--accent); }
.rownum { color: var(--text-dim); text-align: right; background: var(--bg-panel); position: sticky; left: 0; z-index: 2; cursor: pointer; }
.rownum.new { color: var(--green); }
.rownum.del { color: var(--red); }
.gcell.sel { background: rgba(97, 175, 254, 0.10); }
.gcell.rownum.sel { background: rgba(97, 175, 254, 0.22); color: var(--accent); }
.gcell.dirty.sel { background: rgba(229, 192, 123, 0.20); }
.gcell.nullv { color: var(--text-dim); font-style: italic; }
.gcell.dirty { background: rgba(229, 192, 123, 0.13); box-shadow: inset 2px 0 0 var(--yellow); }
.gcell.deleted { opacity: 0.4; text-decoration: line-through; }
.gcell.blob { color: var(--text-dim); }
.gcell.ops { display: flex; align-items: center; }
button.mini { padding: 0 8px; height: 20px; font-size: 11px; opacity: 0; }
.gcell.ops:hover button.mini { opacity: 1; }
.grow { display: contents; }
.padrow { grid-column: 1 / -1; }
.cell-input {
  width: 100%; height: calc(var(--row-h) - 4px);
  font-family: var(--font-mono); font-size: 12px;
  border: 1px solid var(--accent); border-radius: 0; background: var(--bg);
}
.loading { position: absolute; top: 40px; left: 50%; }
</style>
