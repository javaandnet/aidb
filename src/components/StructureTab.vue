<script setup lang="ts">
// 结构标签：表结构查看/修改（加列、删列、改名）、DDL 展示、新建表
import { computed, onMounted, ref, watch } from 'vue'
import { api } from '../api'
import { useConnStore } from '../stores/connections'
import type { WorkspaceTab } from '../stores/workspace'
import type { ColumnInfo } from '../types'

const props = defineProps<{ tab: WorkspaceTab }>()
const conn = useConnStore()

const columns = ref<ColumnInfo[]>([])
const ddl = ref('')
const error = ref('')
const notice = ref('')
const loading = ref(false)

const isNewTable = computed(() => !props.tab.table)
const kind = computed(() => conn.kind ?? 'sqlite')

// 加列表单
const newCol = ref({ name: '', type: kind.value === 'mysql' ? 'varchar(255)' : 'TEXT', notNull: false, pk: false, def: '' })
const colEdits = ref<Record<string, { rename?: string; typeChange?: string }>>({})

// 新建表表单
const createForm = ref({
  tableName: '',
  cols: [{ name: 'id', type: 'INTEGER', notNull: true, pk: true, def: '' } as NewCol],
})
interface NewCol { name: string; type: string; notNull: boolean; pk: boolean; def: string }

function q(name: string): string {
  if (kind.value === 'mysql') return '`' + name.replace(/`/g, '``') + '`'
  return '"' + name.replace(/"/g, '""') + '"'
}

function tableRef(name?: string): string {
  const t = name ?? props.tab.table ?? ''
  if (kind.value === 'mysql') {
    return `${q(props.tab.database ?? '')}.${q(t)}`
  }
  return q(t)
}

async function load() {
  if (!props.tab.connId || !props.tab.table) return
  loading.value = true
  error.value = ''
  try {
    columns.value = await api.listColumns(props.tab.connId, props.tab.database, props.tab.table)
    try {
      ddl.value = await api.getTableDdl(props.tab.connId, props.tab.database, props.tab.table)
    } catch { ddl.value = '-- 无法获取 DDL' }
  } catch (e: any) {
    error.value = String(typeof e === 'string' ? e : e)
  } finally {
    loading.value = false
  }
}

async function runDdl(statements: string[], afterNotice = '') {
  if (!props.tab.connId) return
  error.value = ''
  notice.value = ''
  const preview = statements.join(';\n') + (statements.length > 1 || statements[0]?.length > 120 ? '' : '')
  if (!confirm(`将执行以下 SQL：\n\n${preview}\n\n确认执行？`)) return
  try {
    await api.applyDdl(props.tab.connId, statements)
    conn.invalidateColumns(props.tab.table ?? undefined)
    if (afterNotice) notice.value = afterNotice
    await load()
  } catch (e: any) {
    error.value = String(typeof e === 'string' ? e : e)
  }
}

function colDefSql(c: { name: string; type: string; notNull: boolean; pk: boolean; def: string }): string {
  const parts = [q(c.name), c.type || (kind.value === 'mysql' ? 'varchar(255)' : 'TEXT')]
  if (c.pk) {
    if (kind.value === 'sqlite') {
      parts.push(/integer/i.test(c.type) ? 'PRIMARY KEY AUTOINCREMENT' : 'PRIMARY KEY')
    } else {
      parts.push('NOT NULL PRIMARY KEY')
    }
    return parts.join(' ')
  }
  if (c.notNull) parts.push('NOT NULL')
  if (c.def) parts.push(`DEFAULT ${c.def}`)
  return parts.join(' ')
}

async function addColumn() {
  const c = newCol.value
  if (!c.name.trim()) { error.value = '列名不能为空'; return }
  const stmt = `ALTER TABLE ${tableRef()} ADD COLUMN ${colDefSql({ ...c, pk: false })}`
  await runDdl([stmt], `已添加列 ${c.name}`)
  newCol.value = { name: '', type: kind.value === 'mysql' ? 'varchar(255)' : 'TEXT', notNull: false, pk: false, def: '' }
}

async function dropColumn(name: string) {
  await runDdl([`ALTER TABLE ${tableRef()} DROP COLUMN ${q(name)}`])
}

function renameOf(name: string): string {
  return colEdits.value[name]?.rename ?? ''
}
function typeOf(name: string): string {
  return colEdits.value[name]?.typeChange ?? ''
}
function onRenameInput(name: string, e: Event) {
  const ed = colEdits.value[name]
  if (ed) ed.rename = (e.target as HTMLInputElement).value
}
function onTypeInput(name: string, e: Event) {
  const ed = colEdits.value[name]
  if (ed) ed.typeChange = (e.target as HTMLInputElement).value
}

async function applyColEdit(c: ColumnInfo) {
  const ed = colEdits.value[c.name]
  if (!ed) return
  const stmts: string[] = []
  if (ed.rename && ed.rename !== c.name) {
    if (kind.value === 'mysql') {
      stmts.push(`ALTER TABLE ${tableRef()} CHANGE ${q(c.name)} ${q(ed.rename)} ${ed.typeChange || c.dataType}${c.notNull ? ' NOT NULL' : ''}`)
    } else {
      stmts.push(`ALTER TABLE ${tableRef()} RENAME COLUMN ${q(c.name)} TO ${q(ed.rename)}`)
    }
  } else if (ed.typeChange && ed.typeChange !== c.dataType) {
    if (kind.value === 'mysql') {
      stmts.push(`ALTER TABLE ${tableRef()} MODIFY COLUMN ${q(c.name)} ${ed.typeChange}`)
    } else {
      error.value = 'SQLite 不支持直接改列类型，请使用「SQL 标签」手写迁移语句（建新表→拷贝→改名→删旧表）'
      return
    }
  }
  if (stmts.length) await runDdl(stmts)
  delete colEdits.value[c.name]
}

async function createTable() {
  const f = createForm.value
  error.value = ''
  if (!f.tableName.trim()) { error.value = '表名不能为空'; return }
  const valid = f.cols.filter(c => c.name.trim())
  if (!valid.length) { error.value = '至少一个列'; return }
  const stmt = `CREATE TABLE ${tableRef(f.tableName)} (${valid.map(colDefSql).join(', ')})`
  await runDdl([stmt])
  await conn.refreshTree()
  props.tab.table = f.tableName
  props.tab.title = `结构 · ${f.tableName}`
  await load()
}

function addCreateCol() {
  createForm.value.cols.push({ name: '', type: kind.value === 'mysql' ? 'varchar(255)' : 'TEXT', notNull: false, pk: false, def: '' })
}

watch(() => props.tab.table, load)
onMounted(load)
</script>

<template>
  <div class="structure-tab">
    <!-- 新建表模式 -->
    <div v-if="isNewTable" class="create-mode">
      <h3>新建表</h3>
      <div class="form-row">
        <label>表名</label>
        <input v-model="createForm.tableName" placeholder="my_table" />
      </div>
      <table class="cols-edit">
        <thead>
          <tr><th>列名</th><th>类型</th><th>NOT NULL</th><th>PK</th><th>默认值</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="(c, i) in createForm.cols" :key="i">
            <td><input v-model="c.name" class="mono" /></td>
            <td><input v-model="c.type" class="mono" /></td>
            <td><input v-model="c.notNull" type="checkbox" /></td>
            <td><input v-model="c.pk" type="checkbox" /></td>
            <td><input v-model="c.def" /></td>
            <td><button class="danger mini" :disabled="createForm.cols.length === 1" @click="createForm.cols.splice(i, 1)">×</button></td>
          </tr>
        </tbody>
      </table>
      <div class="row-btns">
        <button @click="addCreateCol">+ 列</button>
        <button class="primary" @click="createTable">创建表</button>
      </div>
      <p v-if="error" class="error-text">{{ error }}</p>
    </div>

    <!-- 已有表模式 -->
    <template v-else>
      <div class="s-toolbar">
        <h3>{{ tab.database ? tab.database + '.' : '' }}{{ tab.table }}</h3>
        <span class="spacer"></span>
        <button @click="load">刷新</button>
      </div>
      <p v-if="error" class="error-text banner">{{ error }}</p>
      <p v-if="notice" class="ok-text banner">{{ notice }}</p>

      <div class="s-body">
        <section>
          <h4>列</h4>
          <table class="cols-edit">
            <thead>
              <tr><th>列名</th><th>类型</th><th>NOT NULL</th><th>默认值</th><th></th><th></th></tr>
            </thead>
            <tbody>
              <tr v-for="c in columns" :key="c.name">
                <td>
                  <span v-if="c.pkPos != null" class="pkmark" title="主键">🔑</span>
                  <input
                    v-if="colEdits[c.name]"
                    :value="renameOf(c.name)"
                    @input="onRenameInput(c.name, $event)"
                    class="mono"
                  />
                  <span v-else class="mono">{{ c.name }}</span>
                </td>
                <td>
                  <input
                    v-if="colEdits[c.name]"
                    :value="typeOf(c.name)"
                    @input="onTypeInput(c.name, $event)"
                    class="mono"
                  />
                  <span v-else class="mono type">{{ c.dataType }}</span>
                </td>
                <td>{{ c.notNull ? '✓' : '' }}</td>
                <td class="mono dim">{{ c.default ?? '' }}</td>
                <td class="edit-ops">
                  <template v-if="colEdits[c.name]">
                    <button class="mini primary" @click="applyColEdit(c)">应用</button>
                    <button class="mini" @click="delete colEdits[c.name]">取消</button>
                  </template>
                  <template v-else>
                    <button class="mini" @click="colEdits[c.name] = { rename: c.name, typeChange: c.dataType }">改名/改类型</button>
                  </template>
                </td>
                <td>
                  <button class="mini danger" :disabled="c.pkPos != null" @click="dropColumn(c.name)">删列</button>
                </td>
              </tr>
            </tbody>
          </table>

          <div class="add-col">
            <input v-model="newCol.name" placeholder="新列名" class="mono" />
            <input v-model="newCol.type" placeholder="类型" class="mono type-input" />
            <label class="chk"><input v-model="newCol.notNull" type="checkbox" />NOT NULL</label>
            <input v-model="newCol.def" placeholder="默认值(可选)" class="def-input" />
            <button class="primary" @click="addColumn">+ 添加列</button>
          </div>
        </section>

        <section>
          <h4>当前 DDL</h4>
          <pre class="ddl mono">{{ ddl || '加载中…' }}</pre>
        </section>
      </div>
    </template>
  </div>
</template>

<style scoped>
.structure-tab { display: flex; flex-direction: column; flex: 1; min-height: 0; }
.s-toolbar { display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--border); background: var(--bg-panel); }
.s-toolbar h3 { font-size: 14px; }
.spacer { flex: 1; }
.banner { padding: 6px 12px; }
.ok-text { color: var(--green); }
.s-body { flex: 1; overflow: auto; padding: 14px; display: flex; flex-direction: column; gap: 18px; }
h4 { margin-bottom: 8px; color: var(--text-dim); font-size: 12px; text-transform: uppercase; }
.cols-edit { width: 100%; border-collapse: collapse; }
.cols-edit th, .cols-edit td { border-bottom: 1px solid var(--border); padding: 5px 8px; text-align: left; font-size: 12px; }
.cols-edit th { color: var(--text-dim); font-weight: 500; }
.cols-edit input[type='text'], .cols-edit input:not([type]) { width: 100%; }
.dim { color: var(--text-dim); }
.type { color: var(--accent); }
.pkmark { margin-right: 4px; }
.edit-ops { white-space: nowrap; }
button.mini { padding: 1px 8px; font-size: 11px; margin-right: 4px; }
.add-col { display: flex; gap: 8px; margin-top: 10px; align-items: center; }
.add-col input { width: 140px; }
.type-input { width: 130px !important; }
.def-input { width: 110px !important; }
.chk { color: var(--text-dim); display: flex; gap: 4px; align-items: center; }
.ddl {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 12px;
  font-size: 12px;
  white-space: pre-wrap;
  user-select: text;
  max-height: 300px;
  overflow: auto;
}
.create-mode { padding: 18px; overflow: auto; }
.create-mode h3 { margin-bottom: 14px; }
.row-btns { display: flex; gap: 10px; margin-top: 12px; }
</style>
