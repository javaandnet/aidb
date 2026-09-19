<script setup lang="ts">
// CSV 导入向导：选文件 -> 列映射 -> 导入
import { computed, reactive, ref } from 'vue'
import { open as openDialog } from '@tauri-apps/plugin-dialog'
import { api } from '../api'
import type { ColumnInfo, CsvPreview } from '../types'

const props = defineProps<{
  connId: string
  database: string | null
  table: string
  columns: ColumnInfo[]
}>()
const emit = defineEmits<{ (e: 'close'): void; (e: 'done'): void }>()

const filePath = ref('')
const preview = ref<CsvPreview | null>(null)
const error = ref('')
const busy = ref(false)
const nullEmpty = ref(true)
// csvIndex -> 目标列名（'' 表示跳过）
const map = reactive<Record<number, string>>({})

async function pickFile() {
  error.value = ''
  const path = await openDialog({ multiple: false, filters: [{ name: 'CSV', extensions: ['csv', 'txt'] }] })
  if (typeof path !== 'string') return
  filePath.value = path
  try {
    preview.value = await api.importPreview(path)
    preview.value.columns.forEach((_, i) => {
      const guess = props.columns.find(c => c.name.toLowerCase() === preview.value!.columns[i].toLowerCase())
      map[i] = guess?.name ?? ''
    })
  } catch (e: any) {
    error.value = String(typeof e === 'string' ? e : e)
    preview.value = null
  }
}

const mapping = computed(() =>
  Object.entries(map)
    .filter(([, col]) => col)
    .map(([idx, col]) => ({ csvIndex: Number(idx), column: col })),
)

async function doImport() {
  if (!mapping.value.length) { error.value = '请至少映射一列'; return }
  busy.value = true
  error.value = ''
  try {
    const n = await api.importCsv(props.connId, props.database, props.table, filePath.value, mapping.value, nullEmpty.value)
    alert(`成功导入 ${n} 行`)
    emit('done')
    emit('close')
  } catch (e: any) {
    error.value = String(typeof e === 'string' ? e : e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="modal-mask">
    <div class="modal import-modal">
      <div class="modal-title">导入 CSV → {{ table }}</div>
      <div class="modal-body">
        <div class="form-row">
          <label>文件</label>
          <input :value="filePath" readonly placeholder="选择 CSV 文件…" class="mono" />
          <button @click="pickFile">浏览…</button>
        </div>
        <template v-if="preview">
          <p class="hint">共 {{ preview.totalRows }} 行数据；下拉选择每列对应的目标表列（跳过 = 不导入）</p>
          <table class="map-table">
            <thead><tr><th>CSV 列</th><th>示例值</th><th>→ 目标列</th></tr></thead>
            <tbody>
              <tr v-for="(col, i) in preview.columns" :key="i">
                <td class="mono">{{ col }}</td>
                <td class="mono sample">{{ preview.sample[0]?.[i] ?? '' }}</td>
                <td>
                  <select v-model="map[i]">
                    <option value="">（跳过）</option>
                    <option v-for="c in columns" :key="c.name" :value="c.name">{{ c.name }}</option>
                  </select>
                </td>
              </tr>
            </tbody>
          </table>
          <label class="chk">
            <input v-model="nullEmpty" type="checkbox" /> 空字符串写入为 NULL
          </label>
        </template>
        <p v-if="error" class="error-text">{{ error }}</p>
      </div>
      <div class="modal-footer">
        <button @click="emit('close')">取消</button>
        <button class="primary" :disabled="!preview || busy" @click="doImport">{{ busy ? '导入中…' : '开始导入' }}</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.import-modal { width: 620px; }
.map-table { width: 100%; border-collapse: collapse; margin: 10px 0; }
.map-table th, .map-table td { border-bottom: 1px solid var(--border); padding: 5px 8px; text-align: left; font-size: 12px; }
.map-table th { color: var(--text-dim); font-weight: 500; }
.sample { color: var(--text-dim); max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chk { display: flex; gap: 6px; align-items: center; color: var(--text-dim); }
.chk input { width: auto; }
</style>
