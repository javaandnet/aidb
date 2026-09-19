<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import TopBar from './components/TopBar.vue'
import Sidebar from './components/Sidebar.vue'
import TabStrip from './components/TabStrip.vue'
import TabBody from './components/TabBody.vue'
import ConnectionManager from './components/ConnectionManager.vue'
import { useConnStore } from './stores/connections'
import { useWorkspace } from './stores/workspace'

const conn = useConnStore()
const ws = useWorkspace()
const showConnManager = ref(false)

function onKeydown(e: KeyboardEvent) {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'n') {
    e.preventDefault()
    if (conn.connectedId) ws.newSqlTab(conn.connectedId, conn.currentDb)
    else showConnManager.value = true
  }
}

onMounted(async () => {
  window.addEventListener('keydown', onKeydown)
  try {
    await conn.loadProfiles()
    if (conn.profiles.length === 1) {
      // 只有一个连接档案时自动尝试连接（失败静默）
      try { await conn.connect(conn.profiles[0]) } catch { /* 需要密码等，等用户操作 */ }
    }
  } catch { /* 后端未就绪时不阻断挂载 */ }
})
onUnmounted(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <div class="app-shell">
    <TopBar @open-connections="showConnManager = true" />
    <div class="app-main">
      <Sidebar />
      <div class="workspace">
        <TabStrip />
        <TabBody />
      </div>
    </div>
    <ConnectionManager v-if="showConnManager" @close="showConnManager = false" />
  </div>
</template>

<style scoped>
.app-shell { display: flex; flex-direction: column; height: 100%; }
.app-main { display: flex; flex: 1; min-height: 0; }
.workspace { display: flex; flex-direction: column; flex: 1; min-width: 0; }
</style>
