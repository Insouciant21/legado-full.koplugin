import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Anchor,
  Badge,
  Button,
  Divider,
  Group,
  Loader,
  Paper,
  SimpleGrid,
  Stack,
  Text,
  ThemeIcon,
} from '@mantine/core'
import {
  api,
  type BookshelfItem,
  type BookshelfRefreshStatus,
  type KindleAutoPublishStatus,
  type KindlePushDelivery,
} from './api'
import { Icon } from './icons'

type AutomationCenterProps = {
  items: BookshelfItem[]
  refreshStatus: BookshelfRefreshStatus | null
  caching: boolean
  onOpenBook: (item: BookshelfItem) => void
  onOpenTasks: () => void
}

type TaskTone = 'active' | 'warning' | 'ready' | 'idle'

function formatTime(value?: string | null): string {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString('zh-CN', {
    month: 'numeric',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function autoStatusCopy(status: KindleAutoPublishStatus | null): { title: string; detail: string; tone: TaskTone } {
  if (!status) return { title: '正在读取 Kindle 状态', detail: '加载设备与上架信息', tone: 'idle' }
  if (!status.enabled || status.state === 'disabled') {
    return { title: '自动上架未启用', detail: '可在设备与任务中启用并查看设备', tone: 'idle' }
  }
  if (status.state === 'publishing') {
    return {
      title: status.current_book_title ? `正在上架《${status.current_book_title}》` : '正在上架书架',
      detail: '完成后 Kindle 联网即可领取',
      tone: 'active',
    }
  }
  if (status.state === 'caching') {
    return {
      title: `${status.blockers.length} 本等待缓存完成`,
      detail: '缓存完一本会立即上架一本',
      tone: 'active',
    }
  }
  if (status.state === 'waiting') {
    return {
      title: status.current_book_title ? `等待上架《${status.current_book_title}》` : '等待上架',
      detail: '全书缓存已完成，正在进行短暂防抖',
      tone: 'active',
    }
  }
  if (status.state === 'blocked' || status.state === 'failed') {
    return {
      title: status.state === 'blocked' ? '自动上架等待处理' : '最近一次自动上架失败',
      detail: status.last_error || '打开设备与任务查看失败书籍',
      tone: 'warning',
    }
  }
  if (status.changes > 0) {
    return {
      title: `${status.changes} 项书架改动待处理`,
      detail: '系统会在缓存完成后逐本上架',
      tone: 'active',
    }
  }
  return {
    title: 'Kindle 书架已同步',
    detail: status.last_published_at ? `上次上架 ${formatTime(status.last_published_at)}` : '当前没有待上架改动',
    tone: 'ready',
  }
}

export function AutomationCenter({
  items,
  refreshStatus,
  caching: _caching,
  onOpenBook,
  onOpenTasks,
}: AutomationCenterProps) {
  const [deliveries, setDeliveries] = useState<KindlePushDelivery[]>([])
  const [autoStatus, setAutoStatus] = useState<KindleAutoPublishStatus | null>(null)
  const [loading, setLoading] = useState(true)
  const [offline, setOffline] = useState(false)

  const loadKindle = useCallback(async (silent = false) => {
    if (!silent) setLoading(true)
    const [deliveryResult, statusResult] = await Promise.allSettled([
      api.kindlePushDeliveries(),
      api.kindleAutoPublishStatus(),
    ])
    if (deliveryResult.status === 'fulfilled') setDeliveries(deliveryResult.value.deliveries)
    if (statusResult.status === 'fulfilled') setAutoStatus(statusResult.value)
    setOffline(deliveryResult.status === 'rejected' && statusResult.status === 'rejected')
    if (!silent) setLoading(false)
  }, [])

  useEffect(() => {
    void loadKindle()
    const timer = window.setInterval(() => void loadKindle(true), 5000)
    return () => window.clearInterval(timer)
  }, [loadKindle])

  const cacheTasks = useMemo(() => items.filter(item => item.cacheState === 'pending' || item.cacheState === 'caching'), [items])
  const queuedCacheCount = cacheTasks.filter(item => item.cacheState === 'pending').length
  const problemItems = useMemo(
    () => items.filter(item => item.cacheState === 'failed' || item.cacheState === 'paused' || item.updateError),
    [items],
  )
  const pendingDeliveries = useMemo(
    () => deliveries.filter(delivery => delivery.state === 'queued' || delivery.state === 'partial'),
    [deliveries],
  )
  const refreshActive = refreshStatus?.state === 'running'
  const refreshDone = refreshStatus?.state === 'completed' ? refreshStatus : null
  const autoCopy = autoStatusCopy(autoStatus)

  const taskCount =
    cacheTasks.length +
    problemItems.length +
    pendingDeliveries.length +
    (refreshActive ? 1 : 0) +
    (autoStatus?.state === 'publishing' || autoStatus?.state === 'waiting' || autoStatus?.state === 'caching' ? 1 : 0)

  return (
    <Paper p="md" withBorder radius="md" aria-label="正在处理">
      <Stack gap="sm">
        <Group justify="space-between" align="center" wrap="wrap" gap="sm">
          <Stack gap={2}>
            <Group gap="xs">
              <Badge
                size="sm"
                variant="dot"
                color={taskCount > 0 ? 'gold' : 'teal'}
              >
                正在处理
              </Badge>
              <Text fw={700} size="sm">
                {taskCount > 0 ? `${taskCount} 项任务在后台推进` : '当前没有待处理任务'}
              </Text>
            </Group>
            <Text size="xs" c="dimmed">
              {taskCount > 0
                ? '可以离开书架继续搜书；完成一本处理一本。'
                : '缓存、目录更新、上架和推送会在这里集中显示。'}
            </Text>
          </Stack>
          <Button
            size="xs"
            variant="light"
            leftSection={<Icon name="device" size={14} />}
            rightSection={<Icon name="arrowRight" size={14} />}
            onClick={onOpenTasks}
          >
            打开设备与任务
          </Button>
        </Group>

        <SimpleGrid cols={{ base: 1, sm: 2, lg: 4 }} spacing="sm">
          <Paper p="sm" withBorder radius="sm" style={{ background: 'var(--canvas)' }}>
            <Group gap="sm" align="flex-start" wrap="nowrap">
              <ThemeIcon size={32} radius="md" variant="light" color={cacheTasks.length > 0 ? 'brand' : 'gray'}>
                <Icon name="cloudDownload" size={16} />
              </ThemeIcon>
              <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
                <Text size="xs" c="dimmed">离线缓存</Text>
                <Text size="sm" fw={600} lineClamp={1}>
                  {cacheTasks.length > 0 ? `${cacheTasks.length - queuedCacheCount} 本缓存中 · ${queuedCacheCount} 本排队` : '没有缓存任务'}
                </Text>
                {cacheTasks[0] ? (
                  <Anchor
                    component="button"
                    type="button"
                    size="xs"
                    ta="left"
                    truncate
                    onClick={() => onOpenBook(cacheTasks[0])}
                    title={cacheTasks[0].name}
                  >
                    {cacheTasks[0].name} · {cacheTasks[0].cachedChapters}/{cacheTasks[0].totalChapters || '?'}
                  </Anchor>
                ) : (
                  <Text size="xs" c="dimmed" truncate>
                    {items.filter(item => item.cacheState === 'ready').length} 本已可离线阅读
                  </Text>
                )}
              </Stack>
            </Group>
          </Paper>

          <Paper p="sm" withBorder radius="sm" style={{ background: 'var(--canvas)' }}>
            <Group gap="sm" align="flex-start" wrap="nowrap">
              <ThemeIcon size={32} radius="md" variant="light" color={refreshActive ? 'brand' : refreshDone ? 'teal' : 'gray'}>
                <Icon name="refresh" size={16} className={refreshActive ? 'spin' : ''} />
              </ThemeIcon>
              <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
                <Text size="xs" c="dimmed">目录更新</Text>
                <Text size="sm" fw={600} lineClamp={1}>
                  {refreshActive
                    ? `正在更新 ${refreshStatus?.completed ?? 0}/${refreshStatus?.total ?? 0}`
                    : refreshDone
                      ? `更新完成 · 新增 ${refreshDone.items.reduce((total, item) => total + Math.max(0, item.newChapters), 0)} 章`
                      : '没有目录任务'}
                </Text>
                <Text size="xs" c="dimmed" truncate>
                  {refreshActive ? '可以继续浏览页面，进度会自动刷新' : '书架目录状态正常'}
                </Text>
              </Stack>
            </Group>
          </Paper>

          <Paper p="sm" withBorder radius="sm" style={{ background: 'var(--canvas)' }}>
            <Group gap="sm" align="flex-start" wrap="nowrap">
              <ThemeIcon
                size={32}
                radius="md"
                variant="light"
                color={autoCopy.tone === 'warning' ? 'gold' : autoCopy.tone === 'ready' ? 'teal' : autoCopy.tone === 'active' ? 'brand' : 'gray'}
              >
                <Icon name="device" size={16} />
              </ThemeIcon>
              <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
                <Text size="xs" c="dimmed">Kindle 上架</Text>
                <Group gap={6} wrap="nowrap">
                  {loading && !autoStatus ? (
                    <>
                      <Loader size={12} />
                      <Text size="sm" fw={600}>正在读取</Text>
                    </>
                  ) : (
                    <Text size="sm" fw={600} truncate>{autoCopy.title}</Text>
                  )}
                </Group>
                <Text size="xs" c="dimmed" truncate>{autoCopy.detail}</Text>
              </Stack>
            </Group>
          </Paper>

          <Paper p="sm" withBorder radius="sm" style={{ background: 'var(--canvas)' }}>
            <Group gap="sm" align="flex-start" wrap="nowrap">
              <ThemeIcon size={32} radius="md" variant="light" color={pendingDeliveries.length > 0 ? 'gold' : 'gray'}>
                <Icon name="upload" size={16} />
              </ThemeIcon>
              <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
                <Text size="xs" c="dimmed">推送队列</Text>
                <Text size="sm" fw={600} lineClamp={1}>
                  {pendingDeliveries.length > 0 ? `${pendingDeliveries.length} 本等待领取` : '队列为空'}
                </Text>
                {pendingDeliveries[0] ? (
                  <Anchor component="button" type="button" size="xs" ta="left" truncate onClick={onOpenTasks}>
                    {pendingDeliveries[0].book_name} · {pendingDeliveries[0].delivered_count}/{pendingDeliveries[0].target_count} 台
                  </Anchor>
                ) : (
                  <Text size="xs" c="dimmed" truncate>
                    {offline ? '暂时无法读取 Kindle 状态' : '设备联网后会在这里领取'}
                  </Text>
                )}
              </Stack>
            </Group>
          </Paper>
        </SimpleGrid>

        {problemItems.length > 0 && (
          <>
            <Divider />
            <Group gap="xs" wrap="wrap">
              <Badge size="sm" variant="light" color="red" leftSection={<Icon name="alert" size={12} />}>
                {problemItems.length} 本需要处理
              </Badge>
              {problemItems.slice(0, 3).map(item => (
                <Button
                  key={`${item.sourceId}\u0000${item.bookUrl}`}
                  size="compact-xs"
                  variant="light"
                  color="gray"
                  onClick={() => onOpenBook(item)}
                >
                  {item.name}
                </Button>
              ))}
              {problemItems.length > 3 && (
                <Text size="xs" c="dimmed">+{problemItems.length - 3}</Text>
              )}
            </Group>
          </>
        )}
      </Stack>
    </Paper>
  )
}
