import { useEffect, useState } from 'react'
import {
  Accordion,
  Alert,
  Badge,
  Button,
  Card,
  Code,
  Group,
  Loader,
  Modal,
  Paper,
  Progress,
  SimpleGrid,
  Stack,
  Tabs,
  Text,
  ThemeIcon,
  Title,
} from '@mantine/core'
import {
  api,
  KindleAutoPublishBlocker,
  KindleAutoPublishStatus,
  KindleDevice,
  KindleDraftResponse,
  KindlePairingCode,
  KindleProgressConflict,
  KindleProgressPosition,
  KindlePublication,
  KindlePushDelivery,
} from './api'
import { Icon } from './icons'

type Props = {
  theme: string
  onClose?: () => void
  mode?: 'modal' | 'page'
}

type KindleTab = 'devices' | 'sync' | 'publish' | 'queue' | 'completed'
type DeliveryTab = 'queue' | 'completed'

function formatSeen(value?: string | null): string {
  if (!value) return '尚未连接'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString('zh-CN')
}

function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '0 B'
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`
}

function progressPositionLabel(position?: KindleProgressPosition | null): string {
  if (!position) return '暂无已保存位置'
  const percent = Math.max(0, Math.min(100, position.chapter_progress * 100))
  return `第 ${position.chapter_index + 1} 章 · ${percent.toFixed(percent >= 10 ? 0 : 1)}%`
}

function progressPositionMeta(position?: KindleProgressPosition | null): string {
  if (!position) return '服务器还没有记录'
  const device = position.device_name || 'WebUI'
  return `${device} · ${formatSeen(position.recorded_at)}`
}

function deliveryStateLabel(delivery: KindlePushDelivery): string {
  if (delivery.state === 'delivered') return '已完成'
  if (delivery.state === 'canceled') return '已取消'
  if (delivery.state === 'partial') return '部分已领取'
  return '等待领取'
}

function deliveryStateColor(delivery: KindlePushDelivery): string {
  if (delivery.state === 'delivered') return 'teal'
  if (delivery.state === 'canceled') return 'gray'
  if (delivery.state === 'partial') return 'yellow'
  return 'brand'
}

function draftOperationLabel(operation: string): string {
  if (operation === 'add_book') return '新增'
  if (operation === 'delete_book') return '移出'
  if (operation === 'change_source') return '换源'
  if (operation === 'update_book') return '更新'
  return operation
}

function draftOperationColor(operation: string): string {
  if (operation === 'add_book') return 'teal'
  if (operation === 'delete_book') return 'red'
  if (operation === 'change_source') return 'indigo'
  if (operation === 'update_book') return 'blue'
  return 'gray'
}

function autoBlockerStateLabel(state: string): string {
  if (state === 'not_started') return '等待开始缓存'
  if (state === 'idle') return '等待缓存'
  if (state === 'pending') return '缓存排队中'
  if (state === 'caching') return '正在缓存'
  if (state === 'partial') return '仅完成部分缓存'
  if (state === 'failed') return '缓存失败'
  if (state === 'paused') return '缓存已暂停'
  return state
}

function autoPublishStateLabel(status: KindleAutoPublishStatus): string {
  if (!status.enabled || status.state === 'disabled') return '自动上架已关闭'
  if (status.state === 'observing') {
    return status.changes > 0 ? '正在检查上架条件' : '正在监听书架改动'
  }
  if (status.state === 'caching') return '等待书籍完成缓存'
  if (status.state === 'blocked') return '缓存失败，自动上架已暂停'
  if (status.state === 'waiting') {
    return status.current_book_title
      ? `《${status.current_book_title}》缓存完成，等待上架`
      : '缓存已完成，等待上架'
  }
  if (status.state === 'publishing') {
    return status.current_book_title
      ? `正在将《${status.current_book_title}》上架到 Kindle`
      : '正在上架到 Kindle 书架'
  }
  if (status.state === 'failed') return '自动上架暂时失败'
  return status.state
}

function autoPublishStateHint(status: KindleAutoPublishStatus): string {
  if (!status.enabled || status.state === 'disabled') {
    return '可通过 LEGADO_KINDLE_AUTO_PUBLISH=true 启用。'
  }
  if (status.state === 'observing') {
    return status.changes > 0
      ? `${status.changes} 项改动正在等待缓存检查。`
      : '当前书架与已上架版本一致。'
  }
  if (status.state === 'caching') {
    return `缓存完一本就上架一本，其他书不会阻塞；当前共 ${status.changes} 项改动，其中 ${status.blockers.length} 本仍在缓存。`
  }
  if (status.state === 'blocked') {
    return '当前没有可上架书籍；请恢复或重试失败项的缓存。其他已就绪书籍仍会优先上架。'
  }
  if (status.state === 'waiting') {
    return '全书缓存门槛已通过，等待短暂防抖后自动上架；不会等待其他书。'
  }
  if (status.state === 'publishing') {
    return '上架完成后 Kindle 下次联网即可拉取。'
  }
  if (status.state === 'failed') {
    return status.next_retry_at
      ? `将在 ${formatSeen(status.next_retry_at)} 后重试。`
      : '可以手动请求立即重试。'
  }
  return ''
}

function autoBlockerProgress(blocker: KindleAutoPublishBlocker): number {
  if (blocker.total_chapters <= 0) return 0
  return Math.max(0, Math.min(100, Math.round(
    blocker.cached_chapters / blocker.total_chapters * 100,
  )))
}

function publishRequestId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  return `publish_${Date.now()}_${Math.random().toString(36).slice(2)}`
}

function DeliveryList({
  deliveries,
  loading,
  kind,
}: {
  deliveries: KindlePushDelivery[]
  loading: boolean
  kind: DeliveryTab
}) {
  if (loading) {
    return (
      <Group justify="center" py="xl">
        <Loader size="sm" />
        <Text size="sm" c="dimmed">正在读取推送记录…</Text>
      </Group>
    )
  }
  if (deliveries.length === 0) {
    return (
      <Paper p="xl" ta="center" style={{ background: 'var(--surface-muted)' }}>
        <Stack align="center" gap="xs">
          <ThemeIcon size="lg" variant="light" color="gray" radius="xl">
            <Icon name={kind === 'queue' ? 'clock' : 'checkCircle'} size={18} />
          </ThemeIcon>
          <Text size="sm" c="dimmed">
            {kind === 'queue' ? '推送队列为空。' : '还没有已完成的推送。'}
          </Text>
        </Stack>
      </Paper>
    )
  }

  return (
    <Stack gap="sm" aria-live="polite">
      {deliveries.map(delivery => {
        const progress = delivery.target_count > 0
          ? Math.min(100, Math.round(delivery.delivered_count / delivery.target_count * 100))
          : 0
        const waitingOrCanceled = delivery.pending_count + delivery.canceled_count
        return (
          <Card key={delivery.delivery_id} p="md">
            <Stack gap="xs">
              <Group justify="space-between" wrap="nowrap">
                <Group gap="xs" wrap="nowrap" style={{ minWidth: 0 }}>
                  <ThemeIcon variant="light" color="brand" size="md">
                    <Icon name="book" size={16} />
                  </ThemeIcon>
                  <Text fw={600} truncate>{delivery.book_name}</Text>
                </Group>
                <Badge size="sm" variant="light" color={deliveryStateColor(delivery)}>
                  {deliveryStateLabel(delivery)}
                </Badge>
              </Group>

              <Group gap="xs">
                <Badge size="xs" variant="outline" color="gray">{delivery.format.toUpperCase()}</Badge>
                <Text size="xs" c="dimmed">{delivery.file_count} 个文件 · {formatBytes(delivery.total_bytes)}</Text>
              </Group>

              <Progress value={progress} color={deliveryStateColor(delivery)} aria-label={`已领取 ${delivery.delivered_count}/${delivery.target_count} 台`} />

              <Group justify="space-between" wrap="wrap" gap="xs">
                <Text size="xs" c="dimmed">
                  已领取 {delivery.delivered_count}/{delivery.target_count} 台
                  {delivery.pending_count > 0 ? ` · 等待 ${delivery.pending_count} 台` : ''}
                  {delivery.canceled_count > 0 ? ` · 取消 ${delivery.canceled_count} 台` : ''}
                  {waitingOrCanceled === 0 ? ' · 全部设备已领取' : ''}
                </Text>
                <Text size="xs" c="dimmed" title={`创建于 ${formatSeen(delivery.created_at)}`}>
                  更新于 {formatSeen(delivery.updated_at)}
                </Text>
              </Group>
            </Stack>
          </Card>
        )
      })}
    </Stack>
  )
}

export function KindleDevicesModal({ onClose, mode = 'modal' }: Props) {
  const [devices, setDevices] = useState<KindleDevice[]>([])
  const [deliveries, setDeliveries] = useState<KindlePushDelivery[]>([])
  const [conflicts, setConflicts] = useState<KindleProgressConflict[]>([])
  const [devicesLoading, setDevicesLoading] = useState(true)
  const [deliveriesLoading, setDeliveriesLoading] = useState(true)
  const [conflictsLoading, setConflictsLoading] = useState(true)
  const [draft, setDraft] = useState<KindleDraftResponse | null>(null)
  const [draftLoading, setDraftLoading] = useState(true)
  const [autoStatus, setAutoStatus] = useState<KindleAutoPublishStatus | null>(null)
  const [autoStatusLoading, setAutoStatusLoading] = useState(true)
  const [autoRetrying, setAutoRetrying] = useState(false)
  const [publishing, setPublishing] = useState(false)
  const [lastPublication, setLastPublication] = useState<KindlePublication | null>(null)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [pairing, setPairing] = useState<KindlePairingCode | null>(null)
  const [activeTab, setActiveTab] = useState<KindleTab>('devices')

  const loadDevices = (silent = false) => {
    if (!silent) setDevicesLoading(true)
    return api.kindleDevices()
      .then(result => setDevices(result.devices))
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取 Kindle 设备失败')
      })
      .finally(() => {
        if (!silent) setDevicesLoading(false)
      })
  }

  const loadDeliveries = (silent = false) => {
    if (!silent) setDeliveriesLoading(true)
    return api.kindlePushDeliveries()
      .then(result => setDeliveries(result.deliveries))
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取推送记录失败')
      })
      .finally(() => {
        if (!silent) setDeliveriesLoading(false)
      })
  }

  const loadDraft = (silent = false) => {
    if (!silent) setDraftLoading(true)
    return api.kindleDraft()
      .then(result => {
        setDraft(result)
      })
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取待上架书架失败')
      })
      .finally(() => {
        if (!silent) setDraftLoading(false)
      })
  }

  const loadAutoStatus = (silent = false) => {
    if (!silent) setAutoStatusLoading(true)
    return api.kindleAutoPublishStatus()
      .then(setAutoStatus)
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取自动上架状态失败')
      })
      .finally(() => {
        if (!silent) setAutoStatusLoading(false)
      })
  }

  const loadConflicts = (silent = false) => {
    if (!silent) setConflictsLoading(true)
    return api.kindleProgressConflicts()
      .then(result => setConflicts(result.conflicts))
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取阅读进度冲突失败')
      })
      .finally(() => {
        if (!silent) setConflictsLoading(false)
      })
  }

  useEffect(() => {
    void loadDevices()
    void loadDeliveries()
    void loadDraft()
    void loadAutoStatus()
    void loadConflicts()
    const deliveryTimer = window.setInterval(() => void loadDeliveries(true), 5_000)
    const autoStatusTimer = window.setInterval(() => void loadAutoStatus(true), 5_000)
    const draftTimer = window.setInterval(() => void loadDraft(true), 10_000)
    const conflictTimer = window.setInterval(() => void loadConflicts(true), 10_000)
    return () => {
      window.clearInterval(deliveryTimer)
      window.clearInterval(autoStatusTimer)
      window.clearInterval(draftTimer)
      window.clearInterval(conflictTimer)
    }
  }, [])

  const queueDeliveries = deliveries.filter(item => item.state === 'queued' || item.state === 'partial')
  const completedDeliveries = deliveries.filter(item => item.state === 'delivered' || item.state === 'canceled')
  const activeLoading = activeTab === 'devices'
    ? devicesLoading
    : activeTab === 'sync'
      ? conflictsLoading
      : activeTab === 'publish'
        ? draftLoading || autoStatusLoading
        : deliveriesLoading

  const createCode = async () => {
    setBusy('pair')
    setError('')
    try {
      setPairing(await api.createKindlePairingCode('Kindle'))
    } catch (err) {
      setError(err instanceof Error ? err.message : '生成配对码失败')
    } finally {
      setBusy('')
    }
  }

  const revoke = async (device: KindleDevice) => {
    if (!window.confirm(`撤销设备“${device.device_name}”吗？该设备之后将无法领取推送，尚未领取的投递会取消。`)) return
    setBusy(device.device_id)
    setError('')
    try {
      await api.revokeKindleDevice(device.device_id)
      await Promise.all([loadDevices(), loadDeliveries()])
    } catch (err) {
      setError(err instanceof Error ? err.message : '撤销设备失败')
    } finally {
      setBusy('')
    }
  }

  const deleteRevoked = async (device: KindleDevice) => {
    if (!window.confirm(`永久删除已撤销设备“${device.device_name}”吗？该操作不可恢复。`)) return
    setBusy(device.device_id)
    setError('')
    try {
      await api.deleteKindleDevice(device.device_id)
      await Promise.all([loadDevices(), loadDeliveries()])
    } catch (err) {
      setError(err instanceof Error ? err.message : '删除设备失败')
    } finally {
      setBusy('')
    }
  }

  const refreshActiveTab = () => {
    setError('')
    if (activeTab === 'devices') {
      void loadDevices()
    } else if (activeTab === 'sync') {
      void loadConflicts()
    } else if (activeTab === 'publish') {
      void Promise.all([loadDraft(), loadAutoStatus()])
    } else {
      void loadDeliveries()
    }
  }

  const publishDraft = async () => {
    if (!draft || draft.changes.length === 0 || publishing) return
    if (!window.confirm('手动上架会跳过“等待全书缓存完成”的自动门槛。确定继续吗？')) return
    setPublishing(true)
    setError('')
    try {
      const publication = await api.publishKindleDraft(draft.draft_version, publishRequestId())
      setLastPublication(publication)
      await Promise.all([loadDraft(), loadAutoStatus(true)])
    } catch (err) {
      setError(err instanceof Error ? err.message : '上架书架失败')
    } finally {
      setPublishing(false)
    }
  }

  const retryAutoPublish = async () => {
    if (autoRetrying) return
    setAutoRetrying(true)
    setError('')
    try {
      setAutoStatus(await api.retryKindleAutoPublish())
      await Promise.all([loadAutoStatus(true), loadDraft(true)])
    } catch (err) {
      setError(err instanceof Error ? err.message : '请求自动上架重试失败')
    } finally {
      setAutoRetrying(false)
    }
  }

  const resolveConflict = async (conflict: KindleProgressConflict, resolution: 'server' | 'kindle') => {
    const busyKey = `${conflict.conflict_id}:${resolution}`
    setBusy(busyKey)
    setError('')
    try {
      await api.resolveKindleProgressConflict(
        conflict.conflict_id,
        resolution,
        conflict.current?.progress_version,
      )
      await loadConflicts()
    } catch (err) {
      setError(err instanceof Error ? err.message : '解决阅读进度冲突失败')
      await loadConflicts(true)
    } finally {
      setBusy('')
    }
  }

  const content = (
    <Stack gap="lg">
      {mode === 'page' && (
        <Stack gap={4}>
          <Text size="xs" fw={700} c="brand" tt="uppercase" lts={1.2}>Kindle</Text>
          <Title order={1} fz={{ base: 26, sm: 32 }}>Kindle 同步中心</Title>
          <Text size="sm" c="dimmed">
            逐本上架持续同步的书架，处理多端阅读进度冲突，并查看 EPUB 推送记录。
          </Text>
        </Stack>
      )}

      <Tabs
        value={activeTab}
        onChange={value => {
          const next = (value as KindleTab) || 'devices'
          setActiveTab(next)
          if (next === 'sync') void loadConflicts()
          if (next === 'publish') void loadDraft()
        }}
      >
        <Tabs.List>
          <Tabs.Tab
            value="devices"
            leftSection={<Icon name="device" size={15} />}
            rightSection={<Badge size="xs" variant="light" color="gray">{devices.length}</Badge>}
          >
            设备
          </Tabs.Tab>
          <Tabs.Tab
            value="sync"
            leftSection={<Icon name="refresh" size={15} />}
            rightSection={<Badge size="xs" variant="light" color={conflicts.length > 0 ? 'yellow' : 'gray'}>{conflicts.length}</Badge>}
          >
            同步冲突
          </Tabs.Tab>
          <Tabs.Tab
            value="publish"
            leftSection={<Icon name="send" size={15} />}
            rightSection={<Badge size="xs" variant="light" color={(draft?.changes.length ?? 0) > 0 ? 'brand' : 'gray'}>{draft?.changes.length ?? 0}</Badge>}
          >
            上架
          </Tabs.Tab>
          <Tabs.Tab
            value="queue"
            leftSection={<Icon name="clock" size={15} />}
            rightSection={<Badge size="xs" variant="light" color={queueDeliveries.length > 0 ? 'gold' : 'gray'}>{queueDeliveries.length}</Badge>}
          >
            队列
          </Tabs.Tab>
          <Tabs.Tab
            value="completed"
            leftSection={<Icon name="checkCircle" size={15} />}
            rightSection={<Badge size="xs" variant="light" color="teal">{completedDeliveries.length}</Badge>}
          >
            已完成
          </Tabs.Tab>
        </Tabs.List>

        <Tabs.Panel value="devices" pt="md">
          <Stack gap="md">
            <Group gap="xs">
              <Button
                loading={busy === 'pair'}
                leftSection={<Icon name="plus" size={15} />}
                onClick={() => void createCode()}
              >
                {busy === 'pair' ? '正在生成…' : '生成配对码'}
              </Button>
              <Button
                variant="default"
                loading={activeLoading}
                leftSection={<Icon name="refresh" size={15} />}
                onClick={refreshActiveTab}
              >
                刷新状态
              </Button>
            </Group>

            {pairing && (
              <Alert color="brand" variant="light" title="请在 5 分钟内完成配对" icon={<Icon name="wifi" size={18} />}>
                <Stack gap="xs">
                  <Text size="sm">
                    在 KOReader 的 Legado server → Find server on LAN 中选择此服务器并输入配对码；无法自动发现时改用 Pair manually。
                  </Text>
                  <Code fz={28} fw={700} p="sm" style={{ letterSpacing: 4, width: 'fit-content' }}>
                    {pairing.pairing_code}
                  </Code>
                  <Text size="xs" c="dimmed">有效期至：{formatSeen(pairing.expires_at)}</Text>
                </Stack>
              </Alert>
            )}

            {devicesLoading ? (
              <Group justify="center" py="xl">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">正在读取设备…</Text>
              </Group>
            ) : devices.length === 0 ? (
              <Paper p="xl" ta="center" style={{ background: 'var(--surface-muted)' }}>
                <Text size="sm" c="dimmed">还没有配对设备。</Text>
              </Paper>
            ) : (
              <Stack gap="xs">
                {devices.map(device => (
                  <Card key={device.device_id} p="md" style={{ opacity: device.revoked_at ? 0.72 : 1 }}>
                    <Group justify="space-between" wrap="nowrap" gap="md">
                      <Group gap="sm" wrap="nowrap" style={{ minWidth: 0 }}>
                        <ThemeIcon size="lg" variant="light" color={device.revoked_at ? 'gray' : 'brand'}>
                          <Icon name="device" size={18} />
                        </ThemeIcon>
                        <Stack gap={2} style={{ minWidth: 0 }}>
                          <Group gap="xs">
                            <Text fw={600} truncate>{device.device_name}</Text>
                            <Badge size="xs" variant="light" color={device.revoked_at ? 'gray' : 'teal'}>
                              {device.revoked_at ? '已撤销' : '已配对'}
                            </Badge>
                          </Group>
                          <Text size="xs" c="dimmed">
                            {device.revoked_at ? `撤销于 ${formatSeen(device.revoked_at)}` : `最后连接：${formatSeen(device.last_seen_at)}`}
                          </Text>
                        </Stack>
                      </Group>
                      <Button
                        size="xs"
                        variant="light"
                        color="red"
                        loading={busy === device.device_id}
                        leftSection={<Icon name="trash" size={14} />}
                        onClick={() => void (device.revoked_at ? deleteRevoked(device) : revoke(device))}
                      >
                        {device.revoked_at ? '删除' : '撤销'}
                      </Button>
                    </Group>
                  </Card>
                ))}
              </Stack>
            )}
          </Stack>
        </Tabs.Panel>

        <Tabs.Panel value="sync" pt="md">
          <Stack gap="md">
            <Group justify="space-between" wrap="wrap" gap="xs">
              <Button
                variant="default"
                loading={activeLoading}
                leftSection={<Icon name="refresh" size={15} />}
                onClick={refreshActiveTab}
              >
                刷新冲突
              </Button>
              <Text size="xs" c="dimmed">Kindle 联网后会自动上传进度并拉取新章节；并发修改会保留在这里。</Text>
            </Group>

            {conflictsLoading ? (
              <Group justify="center" py="xl">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">正在读取阅读进度…</Text>
              </Group>
            ) : conflicts.length === 0 ? (
              <Paper p="xl" ta="center" style={{ background: 'var(--surface-muted)' }}>
                <Stack align="center" gap="xs">
                  <ThemeIcon size="lg" radius="xl" variant="light" color="teal">
                    <Icon name="checkCircle" size={18} />
                  </ThemeIcon>
                  <Text fw={600}>阅读进度已同步</Text>
                  <Text size="xs" c="dimmed">当前没有需要人工处理的位置冲突。</Text>
                </Stack>
              </Paper>
            ) : (
              <Stack gap="sm" aria-live="polite">
                {conflicts.map(conflict => {
                  const serverBusy = busy === `${conflict.conflict_id}:server`
                  const kindleBusy = busy === `${conflict.conflict_id}:kindle`
                  return (
                    <Card key={conflict.conflict_id} p="md">
                      <Stack gap="sm">
                        <Group justify="space-between">
                          <Stack gap={2}>
                            <Text fw={700}>{conflict.title}</Text>
                            <Text size="xs" c="dimmed">创建于 {formatSeen(conflict.created_at)}</Text>
                          </Stack>
                          <Badge color="yellow" variant="light">待处理</Badge>
                        </Group>
                        <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
                          <Paper p="sm" style={{ background: 'var(--surface-muted)' }}>
                            <Stack gap={2}>
                              <Text size="xs" c="dimmed">服务端当前位置</Text>
                              <Text size="sm" fw={600}>{progressPositionLabel(conflict.current)}</Text>
                              <Text size="xs" c="dimmed">{progressPositionMeta(conflict.current)}</Text>
                            </Stack>
                          </Paper>
                          <Paper p="sm" style={{ background: 'var(--surface-muted)' }}>
                            <Stack gap={2}>
                              <Text size="xs" c="dimmed">Kindle 上报位置</Text>
                              <Text size="sm" fw={600}>{progressPositionLabel(conflict.candidate)}</Text>
                              <Text size="xs" c="dimmed">{progressPositionMeta(conflict.candidate)}</Text>
                            </Stack>
                          </Paper>
                        </SimpleGrid>
                        <Group justify="flex-end" gap="xs">
                          <Button
                            size="xs"
                            variant="default"
                            loading={serverBusy}
                            disabled={Boolean(busy)}
                            leftSection={<Icon name="check" size={14} />}
                            onClick={() => void resolveConflict(conflict, 'server')}
                          >
                            保留服务端
                          </Button>
                          <Button
                            size="xs"
                            loading={kindleBusy}
                            disabled={Boolean(busy)}
                            leftSection={<Icon name="download" size={14} />}
                            onClick={() => void resolveConflict(conflict, 'kindle')}
                          >
                            使用 Kindle
                          </Button>
                        </Group>
                      </Stack>
                    </Card>
                  )
                })}
              </Stack>
            )}
          </Stack>
        </Tabs.Panel>

        <Tabs.Panel value="publish" pt="md">
          <Stack gap="md">
            <Group justify="space-between" wrap="wrap" gap="xs">
              <Button
                variant="default"
                loading={activeLoading}
                disabled={publishing}
                leftSection={<Icon name="refresh" size={15} />}
                onClick={refreshActiveTab}
              >
                刷新上架状态
              </Button>
              <Text size="xs" c="dimmed">自动上架每 5 秒刷新；Kindle 只负责阅读书架内容</Text>
            </Group>

            {autoStatusLoading && !autoStatus ? (
              <Group justify="center" py="xl">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">正在读取自动上架状态…</Text>
              </Group>
            ) : autoStatus ? (
              <Card p="md" aria-live="polite">
                <Stack gap="sm">
                  <Group justify="space-between" wrap="nowrap" align="flex-start">
                    <Group gap="sm" wrap="nowrap" align="flex-start">
                      <ThemeIcon
                        size="lg"
                        variant="light"
                        color={autoStatus.state === 'failed' || autoStatus.state === 'blocked' ? 'red' : autoStatus.enabled ? 'brand' : 'gray'}
                      >
                        <Icon name="activity" size={18} />
                      </ThemeIcon>
                      <Stack gap={2}>
                        <Text fw={700}>{autoPublishStateLabel(autoStatus)}</Text>
                        <Text size="xs" c="dimmed">{autoPublishStateHint(autoStatus)}</Text>
                      </Stack>
                    </Group>
                    <Badge variant="light" color={autoStatus.enabled ? 'teal' : 'gray'}>
                      {autoStatus.enabled ? '自动' : '关闭'}
                    </Badge>
                  </Group>

                  {autoStatus.blockers.length > 0 && (
                    <Stack gap="xs">
                      {autoStatus.blockers.map(blocker => {
                        const progress = autoBlockerProgress(blocker)
                        return (
                          <Paper key={blocker.book_id} p="sm" style={{ background: 'var(--surface-muted)' }}>
                            <Stack gap={6}>
                              <Group justify="space-between" wrap="nowrap">
                                <Text size="sm" fw={600} truncate>{blocker.title}</Text>
                                <Text size="xs" c="dimmed">
                                  {autoBlockerStateLabel(blocker.state)}
                                  {blocker.total_chapters > 0 ? ` · ${blocker.cached_chapters}/${blocker.total_chapters}` : ''}
                                </Text>
                              </Group>
                              {blocker.total_chapters > 0 && (
                                <Progress value={progress} size="sm" aria-label={`缓存进度 ${blocker.cached_chapters}/${blocker.total_chapters}`} />
                              )}
                              {blocker.last_error && <Text size="xs" c="red">{blocker.last_error}</Text>}
                            </Stack>
                          </Paper>
                        )
                      })}
                    </Stack>
                  )}

                  {(autoStatus.last_published_at || autoStatus.last_error) && (
                    <Group gap="md" wrap="wrap">
                      {autoStatus.last_published_at && (
                        <Text size="xs" c="dimmed">上次自动上架：{formatSeen(autoStatus.last_published_at)}</Text>
                      )}
                      {autoStatus.last_error && <Text size="xs" c="red">{autoStatus.last_error}</Text>}
                    </Group>
                  )}

                  {autoStatus.enabled && autoStatus.blockers.length === 0 &&
                    (autoStatus.state === 'waiting' || autoStatus.state === 'failed') && (
                      <Group justify="space-between" wrap="wrap" gap="xs">
                        <Text size="xs" c="dimmed">该操作只会跳过防抖，不会绕过全书缓存门槛。</Text>
                        <Button
                          size="xs"
                          loading={autoRetrying}
                          leftSection={<Icon name="upload" size={14} />}
                          onClick={() => void retryAutoPublish()}
                        >
                          {autoRetrying ? '正在请求…' : '立即上架已就绪书籍'}
                        </Button>
                      </Group>
                    )}
                </Stack>
              </Card>
            ) : null}

            {draftLoading ? (
              <Group justify="center" py="xl">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">正在读取书架改动…</Text>
              </Group>
            ) : !draft ? (
              <Paper p="lg" ta="center" style={{ background: 'var(--surface-muted)' }}>
                <Text size="sm" c="dimmed">暂时无法读取待上架书架。</Text>
              </Paper>
            ) : draft.changes.length === 0 ? (
              <Paper p="xl" ta="center" style={{ background: 'var(--surface-muted)' }}>
                <Stack align="center" gap="xs">
                  <ThemeIcon size="lg" radius="xl" variant="light" color="teal">
                    <Icon name="checkCircle" size={18} />
                  </ThemeIcon>
                  <Text fw={600}>已上架书架与当前书架一致</Text>
                  <Text size="xs" c="dimmed">
                    {autoStatus?.last_published_at
                      ? `上次自动上架：${formatSeen(autoStatus.last_published_at)}`
                      : lastPublication
                        ? `刚刚上架：${formatSeen(lastPublication.published_at)}`
                        : draft.base_publication_id
                          ? `当前上架版本：${draft.base_publication_id}`
                          : '还没有需要上架的书架改动。'}
                  </Text>
                </Stack>
              </Paper>
            ) : (
              <Card p="md">
                <Stack gap="md">
                  <Group justify="space-between" wrap="nowrap">
                    <Stack gap={2}>
                      <Text fw={700}>{draft.base_publication_id ? '待上架书架改动' : '首次上架书架'}</Text>
                      <Text size="xs" c="dimmed">
                        {draft.changes.length} 项改动 · {draft.base_publication_id ? '更新已有上架版本' : '建立第一份 Kindle 上架版本'}
                      </Text>
                    </Stack>
                    <Badge size="lg" variant="light">{draft.changes.length}</Badge>
                  </Group>

                  <Text size="xs" c="dimmed">
                    一本书的全文缓存成功后，Server 会立即为这本书生成独立上架版本。其他书仍在缓存或失败不会阻塞它，也不会把未完成的书上架给 Kindle。
                  </Text>

                  <Stack gap="xs" aria-label="待上架书架改动">
                    {draft.changes.map(change => (
                      <Paper key={`${change.operation}:${change.book_id}`} p="xs" style={{ background: 'var(--surface-muted)' }}>
                        <Group justify="space-between" wrap="nowrap" gap="sm">
                          <Group gap="xs" wrap="nowrap" style={{ minWidth: 0 }}>
                            <Badge size="xs" variant="light" color={draftOperationColor(change.operation)}>
                              {draftOperationLabel(change.operation)}
                            </Badge>
                            <Text size="sm" fw={600} truncate>{change.title}</Text>
                          </Group>
                          <Text size="xs" c="dimmed" truncate maw={220} title={change.book_id}>{change.book_id}</Text>
                        </Group>
                      </Paper>
                    ))}
                  </Stack>

                  <Accordion variant="contained">
                    <Accordion.Item value="manual-publish">
                      <Accordion.Control>高级操作：手动上架</Accordion.Control>
                      <Accordion.Panel>
                        <Stack gap="xs">
                          <Text size="xs" c="dimmed">仅用于排障。手动上架会跳过全书缓存完成检查。</Text>
                          <Button
                            size="xs"
                            variant="default"
                            w="fit-content"
                            loading={publishing}
                            disabled={publishing || autoStatus?.state === 'publishing'}
                            leftSection={<Icon name="upload" size={14} />}
                            onClick={() => void publishDraft()}
                          >
                            {publishing ? '正在上架…' : '强制上架当前改动'}
                          </Button>
                        </Stack>
                      </Accordion.Panel>
                    </Accordion.Item>
                  </Accordion>
                </Stack>
              </Card>
            )}
          </Stack>
        </Tabs.Panel>

        <Tabs.Panel value="queue" pt="md">
          <Stack gap="md">
            <Group justify="space-between">
              <Button
                variant="default"
                loading={activeLoading}
                leftSection={<Icon name="refresh" size={15} />}
                onClick={refreshActiveTab}
              >
                刷新记录
              </Button>
              <Text size="xs" c="dimmed">队列每 5 秒自动刷新</Text>
            </Group>
            <DeliveryList deliveries={queueDeliveries} loading={deliveriesLoading} kind="queue" />
          </Stack>
        </Tabs.Panel>

        <Tabs.Panel value="completed" pt="md">
          <Stack gap="md">
            <Group justify="space-between">
              <Button
                variant="default"
                loading={activeLoading}
                leftSection={<Icon name="refresh" size={15} />}
                onClick={refreshActiveTab}
              >
                刷新记录
              </Button>
              <Text size="xs" c="dimmed">队列每 5 秒自动刷新</Text>
            </Group>
            <DeliveryList deliveries={completedDeliveries} loading={deliveriesLoading} kind="completed" />
          </Stack>
        </Tabs.Panel>
      </Tabs>

      {error && (
        <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
          {error}
        </Alert>
      )}
    </Stack>
  )

  if (mode === 'page') return content

  return (
    <Modal opened onClose={onClose ?? (() => undefined)} size="xl" title="Kindle 同步中心">
      {content}
    </Modal>
  )
}
