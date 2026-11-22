import { useEffect, useState } from 'react'
import {
  Alert,
  Badge,
  Button,
  Checkbox,
  Divider,
  Group,
  Modal,
  NumberInput,
  Paper,
  Progress,
  SegmentedControl,
  Select,
  SimpleGrid,
  Stack,
  Text,
  TextInput,
} from '@mantine/core'
import { api, BookshelfExportRequest, BookshelfExportStatus, BookshelfItem, KindleDevice, KindlePushDelivery } from './api'
import { Icon } from './icons'

type Props = {
  item: BookshelfItem
  onClose: () => void
}

export function BookExportModal({ item, onClose }: Props) {
  const [format, setFormat] = useState<'txt' | 'epub'>('epub')
  const [parallel, setParallel] = useState(false)
  const [useReplace, setUseReplace] = useState(true)
  const [includeChapterTitle, setIncludeChapterTitle] = useState(true)
  const [epubScope, setEpubScope] = useState('')
  const [epubSize, setEpubSize] = useState(1)
  const [charset, setCharset] = useState('UTF-8')
  const [job, setJob] = useState<BookshelfExportStatus | null>(null)
  const [starting, setStarting] = useState(false)
  const [error, setError] = useState('')
  const [devices, setDevices] = useState<KindleDevice[]>([])
  const [devicesLoading, setDevicesLoading] = useState(true)
  const [pushToKindle, setPushToKindle] = useState(false)
  const [selectedDeviceIds, setSelectedDeviceIds] = useState<string[]>([])
  const [pushDelivery, setPushDelivery] = useState<KindlePushDelivery | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    void api.kindleDevices()
      .then(result => {
        if (controller.signal.aborted) return
        const active = result.devices.filter(device => !device.revoked_at)
        setDevices(active)
        let stored: string | null = null
        try {
          stored = window.localStorage.getItem('legado-kindle-push-enabled')
        } catch {
          stored = null
        }
        const preferred = stored === null ? true : stored === '1'
        setPushToKindle(active.length > 0 && preferred)
        setSelectedDeviceIds(active.map(device => device.device_id))
      })
      .catch(() => {
        if (!controller.signal.aborted) setDevices([])
      })
      .finally(() => {
        if (!controller.signal.aborted) setDevicesLoading(false)
      })
    return () => controller.abort()
  }, [])

  useEffect(() => {
    if (!job || job.status === 'ready' || job.status === 'failed') return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void api.bookshelfExportStatus(job.jobId, controller.signal)
        .then(setJob)
        .catch(err => {
          if (!controller.signal.aborted) {
            const message = err instanceof Error ? err.message : '查询导出进度失败'
            setError(message)
            setJob(current => current ? { ...current, status: 'failed', message } : current)
          }
        })
    }, 800)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [job])

  useEffect(() => {
    if (!job?.kindleDeliveryId || (job.kindlePushState !== 'queued' && job.kindlePushState !== 'partial')) return
    let active = true
    let timer = 0
    const poll = async () => {
      try {
        const result = await api.kindlePushDeliveries()
        if (!active) return
        const current = result.deliveries.find(item => item.delivery_id === job.kindleDeliveryId)
        if (current) setPushDelivery(current)
        if (!current || current.state === 'queued' || current.state === 'partial') {
          timer = window.setTimeout(() => void poll(), 3000)
        }
      } catch {
        if (active) timer = window.setTimeout(() => void poll(), 5000)
      }
    }
    void poll()
    return () => {
      active = false
      window.clearTimeout(timer)
    }
  }, [job?.kindleDeliveryId, job?.kindlePushState])

  const start = async () => {
    if (starting) return
    setStarting(true)
    setError('')
    setJob(null)
    const request: BookshelfExportRequest = {
      sourceId: item.sourceId,
      bookUrl: item.bookUrl,
      format,
      parallel,
      useReplace,
      includeChapterTitle,
      epubSize,
      charset,
      ...(format === 'epub' && epubScope.trim() ? { epubScope: epubScope.trim() } : {}),
      ...(format === 'epub' && pushToKindle && selectedDeviceIds.length > 0
        ? { pushToKindle: true, kindleDeviceIds: selectedDeviceIds }
        : {}),
    }
    try {
      setJob(await api.startBookshelfExport(request))
    } catch (err) {
      setError(err instanceof Error ? err.message : '启动导出失败')
    } finally {
      setStarting(false)
    }
  }

  const progress = job && job.selectedChapters > 0
    ? Math.min(100, Math.round(job.processedChapters / job.selectedChapters * 100))
    : 0
  const exporting = Boolean(job && !['ready', 'failed'].includes(job.status))

  return (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      title={
        <Stack gap={2}>
          <Group gap="xs">
            <Text fw={700} size="lg">{item.name}</Text>
            <Badge size="xs" variant="light">下载与导出</Badge>
          </Group>
          <Text size="xs" c="dimmed">{item.author || '未知作者'}</Text>
        </Stack>
      }
    >
      <Stack gap="md">
        <Stack gap={6}>
          <Text size="sm" fw={600}>导出格式</Text>
          <SegmentedControl
            fullWidth
            disabled={exporting}
            value={format}
            onChange={value => {
              const next = value as 'txt' | 'epub'
              setFormat(next)
              if (next === 'txt') setPushToKindle(false)
            }}
            data={[
              { value: 'epub', label: 'EPUB 2.0（支持 Kindle 推送）' },
              { value: 'txt', label: 'TXT 纯文本' },
            ]}
          />
        </Stack>

        {format === 'txt' ? (
          <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
            <Select
              label="文件编码"
              value={charset}
              onChange={value => setCharset(value || 'UTF-8')}
              data={['UTF-8', 'GB18030', 'GBK', 'UTF-16LE']}
            />
            <Stack justify="flex-end" pb={4}>
              <Checkbox
                label="包含章节标题"
                checked={includeChapterTitle}
                onChange={event => setIncludeChapterTitle(event.currentTarget.checked)}
              />
            </Stack>
          </SimpleGrid>
        ) : (
          <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
            <TextInput
              label="章节范围（可空）"
              value={epubScope}
              onChange={event => setEpubScope(event.target.value)}
              placeholder="例如 1-20,25,30-40"
            />
            <NumberInput
              label="每个文件章节数"
              min={1}
              value={epubSize}
              onChange={value => setEpubSize(Math.max(1, Number(value) || 1))}
            />
          </SimpleGrid>
        )}

        <Group gap="lg" wrap="wrap">
          <Checkbox
            label="章节并发下载（最多 9 章）"
            checked={parallel}
            onChange={event => setParallel(event.currentTarget.checked)}
          />
          <Checkbox
            label="应用正文与标题净化规则"
            checked={useReplace}
            onChange={event => setUseReplace(event.currentTarget.checked)}
          />
        </Group>

        <Paper p="sm" style={{ background: 'var(--surface-muted)' }}>
          <Stack gap="xs">
            <Checkbox
              label="导出完成后自动推送到 Kindle"
              checked={format === 'epub' && pushToKindle}
              disabled={format !== 'epub' || devicesLoading || devices.length === 0}
              onChange={event => {
                const checked = event.currentTarget.checked
                setPushToKindle(checked)
                try {
                  window.localStorage.setItem('legado-kindle-push-enabled', checked ? '1' : '0')
                } catch {
                  // ignore
                }
              }}
            />
            <Text size="xs" c="dimmed">
              {format !== 'epub'
                ? 'Kindle 推送仅支持 EPUB 格式。'
                : devicesLoading
                  ? '正在检查配对设备…'
                  : devices.length === 0
                    ? '还没有配对设备，请前往“设备与任务”完成配对。'
                    : `${devices[0]?.device_name}${devices.length > 1 ? ` 等 ${devices.length} 台设备` : ''} 下次联网时会自动领取。`}
            </Text>
            {format === 'epub' && devices.length > 1 && pushToKindle && (
              <Group gap="md" wrap="wrap" pt={4}>
                {devices.map(device => (
                  <Checkbox
                    key={device.device_id}
                    size="xs"
                    label={device.device_name}
                    checked={selectedDeviceIds.includes(device.device_id)}
                    onChange={event => {
                      const checked = event.currentTarget.checked
                      setSelectedDeviceIds(current => checked
                        ? [...new Set([...current, device.device_id])]
                        : current.filter(id => id !== device.device_id))
                    }}
                  />
                ))}
              </Group>
            )}
          </Stack>
        </Paper>

        {error && (
          <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
            {error}
          </Alert>
        )}

        {job && (
          <Paper p="md" radius="md">
            <Stack gap="xs">
              <Group justify="space-between">
                <Text size="sm" fw={600}>{job.message}</Text>
                <Badge size="sm" variant="light" color={job.status === 'failed' ? 'red' : job.status === 'ready' ? 'teal' : 'brand'}>
                  {job.processedChapters}/{job.selectedChapters || '?'} 章
                </Badge>
              </Group>
              <Progress value={progress} color={job.status === 'failed' ? 'red' : 'brand'} animated={exporting} />
              <Text size="xs" c="dimmed">
                单书章节并发 {job.chapterConcurrency} · 多书串行 {job.bookConcurrency}
                {job.failedChapters > 0 ? ` · 失败 ${job.failedChapters} 章` : ''}
                {job.imageFailures > 0 ? ` · 图片失败 ${job.imageFailures} 张` : ''}
              </Text>
              {job.files.length > 0 && (
                <Group gap="xs" wrap="wrap" pt={4}>
                  {job.files.map(file => (
                    <Button
                      key={file.fileId}
                      component="a"
                      href={file.downloadUrl}
                      download={file.fileName}
                      size="xs"
                      leftSection={<Icon name="download" size={14} />}
                    >
                      {file.fileName}
                    </Button>
                  ))}
                </Group>
              )}
              {(pushDelivery?.state || job.kindlePushState) && (
                <Alert
                  variant="light"
                  color={(pushDelivery?.state || job.kindlePushState) === 'canceled' ? 'red' : 'brand'}
                  icon={<Icon name="device" size={16} />}
                >
                  {pushDelivery
                    ? pushDelivery.state === 'delivered'
                      ? 'Kindle 已领取全部文件'
                      : pushDelivery.state === 'canceled'
                        ? '目标设备已撤销，未领取的投递已取消'
                        : `已领取 ${pushDelivery.delivered_count} 台，仍有 ${pushDelivery.pending_count} 台等待领取`
                          + (pushDelivery.canceled_count > 0 ? `；${pushDelivery.canceled_count} 台已撤销` : '')
                    : job.kindlePushMessage || 'Kindle 投递状态已更新'}
                </Alert>
              )}
            </Stack>
          </Paper>
        )}

        <Divider />

        <Group justify="flex-end" gap="xs">
          <Button variant="default" onClick={onClose}>关闭</Button>
          <Button
            loading={starting || exporting}
            leftSection={<Icon name="download" size={15} />}
            onClick={() => void start()}
            disabled={starting || exporting || (format === 'epub' && pushToKindle && selectedDeviceIds.length === 0)}
          >
            {starting ? '正在创建任务…' : exporting ? '正在导出…' : '开始导出'}
          </Button>
        </Group>
      </Stack>
    </Modal>
  )
}
