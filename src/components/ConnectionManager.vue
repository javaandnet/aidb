<script setup lang="ts">
// 连接管理器：档案列表 + 新建/编辑 + 测试 + 连接/断开
import { ref, reactive } from 'vue'
import { open as openDialog } from '@tauri-apps/plugin-dialog'
import { api } from '../api'
import { useConnStore } from '../stores/connections'
import { useWorkspace } from '../stores/workspace'
import type { ConnectionProfile } from '../types'

const emit = defineEmits<{ (e: 'close'): void }>()
const conn = useConnStore()
const ws = useWorkspace()

const editing = ref<ConnectionProfile | null>(null)
const showForm = ref(false)
const form = reactive({
  id: '',
  name: '',
  kind: 'sqlite' as 'sqlite' | 'mysql',
  filePath: '',
  host: '127.0.0.1',
  port: 3306,
  user: 'root',
  password: '',
  defaultDb: '',
})
const formError = ref('')
const testing = ref(false)
const testResult = ref('')
const busyId = ref('')

function fillForm(p?: ConnectionProfile) {
  formError.value = ''
  testResult.value = ''
  editing.value = p ?? null
  form.id = p?.id ?? ''
  form.name = p?.name ?? ''
  form.kind = p?.kind ?? 'sqlite'
  form.filePath = p?.filePath ?? ''
  form.host = p?.host ?? '127.0.0.1'
  form.port = p?.port ?? 3306
  form.user = p?.user ?? 'root'
  form.password = ''
  form.defaultDb = p?.defaultDb ?? ''
  showForm.value = true
}

function inputPayload() {
  return {
    id: form.id,
    name: form.name || (form.kind === 'sqlite' ? form.filePath.split('/').pop() ?? '' : `${form.user}@${form.host}`),
    kind: form.kind,
    filePath: form.kind === 'sqlite' ? form.filePath : null,
    host: form.kind === 'mysql' ? form.host : null,
    port: form.kind === 'mysql' ? form.port : null,
    user: form.kind === 'mysql' ? form.user : null,
    defaultDb: form.kind === 'mysql' && form.defaultDb ? form.defaultDb : null,
  }
}

async function pickFile() {
  const path = await openDialog({
    multiple: false,
    filters: [{ name: 'SQLite', extensions: ['db', 'sqlite', 'sqlite3', 'db3'] }],
  })
  if (typeof path === 'string') {
    form.filePath = path
    if (!form.name) form.name = path.split('/').pop() ?? ''
  }
}

async function doTest() {
  testing.value = true
  testResult.value = ''
  try {
    const v = await api.testConnection(inputPayload(), form.password || null)
    testResult.value = `✓ 连接成功：${v}`
  } catch (e: any) {
    testResult.value = `✗ ${typeof e === 'string' ? e : e?.message ?? JSON.stringify(e)}`
  } finally {
    testing.value = false
  }
}

async function doSave() {
  formError.value = ''
  try {
    await api.saveConnection(inputPayload(), form.password || null)
    await conn.loadProfiles()
    showForm.value = false
  } catch (e: any) {
    formError.value = String(typeof e === 'string' ? e : e)
  }
}

async function doDelete(p: ConnectionProfile) {
  if (!confirm(`删除连接档案「${p.name}」？（不会删除数据库文件）`)) return
  await api.deleteConnection(p.id)
  if (conn.connectedId === p.id) {
    conn.connectedId = null
    ws.onConnectionLost()
  }
  await conn.loadProfiles()
}

async function doConnect(p: ConnectionProfile) {
  busyId.value = p.id
  try {
    await conn.connect(p)
    emit('close')
  } catch (e: any) {
    let msg = typeof e === 'string' ? e : e?.message ?? JSON.stringify(e)
    // MySQL 密码未存 Keychain 时，弹窗补输入
    if (p.kind === 'mysql') {
      const pwd = prompt(`连接 ${p.name}（输入密码，留空取消）：`)
      if (pwd) {
        try {
          await conn.connect(p, pwd)
          await api.saveConnection(
            { id: p.id, name: p.name, kind: p.kind, host: p.host, port: p.port, user: p.user, defaultDb: p.defaultDb, filePath: null },
            pwd,
          )
          emit('close')
          busyId.value = ''
          return
        } catch (e2: any) {
          msg = String(typeof e2 === 'string' ? e2 : e2)
        }
      }
    }
    alert(`连接失败：${msg}`)
  } finally {
    busyId.value = ''
  }
}

async function doDisconnect() {
  await conn.disconnect()
  ws.onConnectionLost()
}
</script>

<template>
  <div class="modal-mask" @click.self="emit('close')">
    <div class="modal">
      <div class="modal-title">连接管理</div>
      <div class="modal-body">
        <table class="conn-list">
          <thead>
            <tr><th>名称</th><th>类型</th><th>目标</th><th class="ops">操作</th></tr>
          </thead>
          <tbody>
            <tr v-for="p in conn.profiles" :key="p.id" :class="{ active: p.id === conn.connectedId }">
              <td>{{ p.name }}</td>
              <td><span class="badge">{{ p.kind }}</span></td>
              <td class="target mono">
                {{ p.kind === 'sqlite' ? p.filePath : `${p.user}@${p.host}:${p.port}/${p.defaultDb ?? ''}` }}
              </td>
              <td class="ops">
                <template v-if="p.id === conn.connectedId">
                  <button @click="doDisconnect">断开</button>
                </template>
                <template v-else>
                  <button class="primary" :disabled="busyId === p.id" @click="doConnect(p)">连接</button>
                </template>
                <button @click="fillForm(p)">编辑</button>
                <button class="danger" @click="doDelete(p)">删除</button>
              </td>
            </tr>
            <tr v-if="!conn.profiles.length">
              <td colspan="4" class="empty hint">还没有连接档案，点击「新建连接」开始</td>
            </tr>
          </tbody>
        </table>
        <div class="add-row">
          <button class="primary" @click="fillForm()">+ 新建连接</button>
        </div>
      </div>
      <div class="modal-footer">
        <button @click="emit('close')">关闭</button>
      </div>
    </div>

    <!-- 编辑表单 -->
    <div v-if="showForm" class="modal-mask">
      <div class="modal form-modal">
        <div class="modal-title">{{ editing ? '编辑连接' : '新建连接' }}</div>
        <div class="modal-body">
          <div class="form-row">
            <label>类型</label>
            <select v-model="form.kind" :disabled="!!editing">
              <option value="sqlite">SQLite</option>
              <option value="mysql">MySQL</option>
            </select>
          </div>
          <template v-if="form.kind === 'sqlite'">
            <div class="form-row">
              <label>数据库文件</label>
              <input v-model="form.filePath" placeholder="/path/to/database.db" class="mono" />
              <button @click="pickFile">浏览…</button>
            </div>
          </template>
          <template v-else>
            <div class="form-row">
              <label>主机</label>
              <input v-model="form.host" placeholder="127.0.0.1" />
              <label class="inline">端口</label>
              <input v-model.number="form.port" type="number" class="port" />
            </div>
            <div class="form-row">
              <label>用户</label>
              <input v-model="form.user" placeholder="root" />
            </div>
            <div class="form-row">
              <label>密码</label>
              <input v-model="form.password" type="password" :placeholder="editing ? '留空则不修改（存于 Keychain）' : ''" />
            </div>
            <div class="form-row">
              <label>默认数据库</label>
              <input v-model="form.defaultDb" placeholder="可留空，连接后再选择" />
            </div>
          </template>
          <div class="form-row">
            <label>连接名称</label>
            <input v-model="form.name" placeholder="自动根据目标命名" />
          </div>
          <p v-if="testResult" :class="testResult.startsWith('✓') ? 'ok-text' : 'error-text'" class="mono">{{ testResult }}</p>
          <p v-if="formError" class="error-text">{{ formError }}</p>
        </div>
        <div class="modal-footer">
          <button :disabled="testing" @click="doTest">{{ testing ? '测试中…' : '测试连接' }}</button>
          <button @click="showForm = false">取消</button>
          <button class="primary" @click="doSave">保存</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.conn-list { width: 100%; border-collapse: collapse; }
.conn-list th, .conn-list td {
  text-align: left; padding: 7px 8px; border-bottom: 1px solid var(--border);
}
.conn-list th { color: var(--text-dim); font-weight: 500; font-size: 12px; }
.conn-list tr.active td { background: var(--bg-selected); }
.conn-list .target { color: var(--text-dim); font-size: 11.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 280px; }
.ops { white-space: nowrap; }
.ops button { margin-right: 6px; }
.empty { text-align: center; padding: 18px !important; }
.add-row { margin-top: 14px; }
.form-modal { width: 520px; }
.inline { width: auto !important; }
.port { width: 76px; flex: none !important; }
.ok-text { color: var(--green); }
</style>
