import { useState, useEffect, useRef, useMemo } from 'react'
import {
  ActionIcon,
  Badge,
  Button,
  Card,
  Group,
  Modal,
  Progress,
  ScrollArea,
  Stack,
  Tabs,
  Text,
  TextInput,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, SourceHealthCheckItem, SourceSummary } from './api'
import { Icon } from './icons'

interface SourceHealthModalProps {
  sources: SourceSummary[]
  onClose: () => void
  onSourcesChange: () => void
  onToast: (message: string, type?: 'info' | 'success' | 'error') => void
}

type TabFilter = 'all' | 'valid' | 'slow' | 'failed'

export function SourceHealthModal({
  sources,
  onClose,
  onSourcesChange,
  onToast,
}: SourceHealthModalProps) {
  const { t } = useTranslation()
  const [running, setRunning] = useState(false)
  const [progress, setProgress] = useState<{ total: number; checked: number }>({ total: sources.length, checked: 0 })
  const [results, setResults] = useState<SourceHealthCheckItem[]>([])
  const [activeTab, setActiveTab] = useState<TabFilter>('all')
  const [filterQuery, setFilterQuery] = useState('')
  const [durationMs, setDurationMs] = useState(0)
  const [busyAction, setBusyAction] = useState<string | null>(null)
  const timerRef = useRef<number | null>(null)
  const startTimeRef = useRef<number>(0)

  const stats = useMemo(() => {
    let valid = 0
    let slow = 0
    let failed = 0
    for (const r of results) {
      if (r.statusCategory === 'valid') valid++
      else if (r.statusCategory === 'slow') slow++
      else failed++
    }
    return {
      total: results.length,
      valid,
      slow,
      failed,
    }
  }, [results])

  const filteredResults = useMemo(() => {
    return results.filter(item => {
      if (activeTab === 'valid' && item.statusCategory !== 'valid') return false
      if (activeTab === 'slow' && item.statusCategory !== 'slow') return false
      if (activeTab === 'failed' && item.statusCategory !== 'failed' && item.statusCategory !== 'blocked') return false
      if (filterQuery) {
        const q = filterQuery.toLowerCase()
        return item.name.toLowerCase().includes(q) || item.id.toLowerCase().includes(q)
      }
      return true
    })
  }, [results, activeTab, filterQuery])

  const startCheck = async (targetIds?: string[]) => {
    const idsToCheck = targetIds ?? sources.map(s => s.id)
    if (idsToCheck.length === 0) {
      onToast(t('source.noSourcesToCheck', '没有可检测的书源'), 'info')
      return
    }
    setRunning(true)
    setProgress({ total: idsToCheck.length, checked: 0 })
    startTimeRef.current = Date.now()
    if (timerRef.current) clearInterval(timerRef.current)
    timerRef.current = window.setInterval(() => {
      setDurationMs(Date.now() - startTimeRef.current)
    }, 100)

    try {
      const resp = await api.healthCheckSources(idsToCheck, 5000)
      if (targetIds && targetIds.length < sources.length) {
        // Merge partial results
        setResults(prev => {
          const map = new Map(prev.map(item => [item.id, item]))
          for (const item of resp.results) {
            map.set(item.id, item)
          }
          return Array.from(map.values())
        })
      } else {
        setResults(resp.results)
      }
      setDurationMs(resp.durationMs)
      setProgress({ total: idsToCheck.length, checked: idsToCheck.length })
      onToast(
        t('source.healthCheckComplete', {
          success: resp.successCount,
          slow: resp.slowCount,
          failed: resp.failedCount,
          defaultValue: `体检完成：${resp.successCount} 个正常，${resp.slowCount} 个迟缓，${resp.failedCount} 个失效`,
        }),
        resp.failedCount > 0 ? 'info' : 'success'
      )
    } catch (err) {
      onToast(err instanceof Error ? err.message : t('source.healthCheckFailed', '体检请求失败'), 'error')
    } finally {
      setRunning(false)
      if (timerRef.current) {
        clearInterval(timerRef.current)
        timerRef.current = null
      }
    }
  }

  useEffect(() => {
    // Auto-start on modal mount
    void startCheck()
    return () => {
      if (timerRef.current) clearInterval(timerRef.current)
    }
  }, [])

  const handleBatchDisableFailed = async () => {
    const failedItems = results.filter(r => r.statusCategory === 'failed' || r.statusCategory === 'blocked')
    if (failedItems.length === 0) {
      onToast(t('source.noFailedSourcesToDisable', '当前无失效书源需要停用'), 'info')
      return
    }
    setBusyAction('disable_failed')
    try {
      const resp = await api.batchSources('disable', failedItems.map(i => i.id))
      onToast(t('source.disabledFailedSuccess', { count: resp.affected, defaultValue: `已停用 ${resp.affected} 个失效书源` }), 'success')
      onSourcesChange()
    } catch (err) {
      onToast(err instanceof Error ? err.message : t('source.disableSourcesFailed', '停用失败'), 'error')
    } finally {
      setBusyAction(null)
    }
  }

  const handleBatchDeleteFailed = async () => {
    const failedItems = results.filter(r => r.statusCategory === 'failed' || r.statusCategory === 'blocked')
    if (failedItems.length === 0) {
      onToast(t('source.noFailedSourcesToDelete', '当前无失效书源需要删除'), 'info')
      return
    }
    const separator = t('common.separator', '、')
    const names = failedItems.slice(0, 3).map(i => i.name).join(separator) + (failedItems.length > 3 ? t('source.etcCount', ' 等共 {{count}} 个', { count: failedItems.length }) : '')
    if (!confirm(t('source.deleteFailedConfirm', {
      count: failedItems.length,
      names,
      defaultValue: `确定要彻底删除以下 ${failedItems.length} 个失效书源吗？\n（${names}）\n删除后不可恢复！`,
    }))) {
      return
    }
    setBusyAction('delete_failed')
    try {
      const resp = await api.batchSources('delete', failedItems.map(i => i.id))
      onToast(t('source.deletedFailedSuccess', { count: resp.affected, defaultValue: `已删除 ${resp.affected} 个失效书源` }), 'success')
      setResults(prev => prev.filter(r => r.statusCategory !== 'failed' && r.statusCategory !== 'blocked'))
      onSourcesChange()
    } catch (err) {
      onToast(err instanceof Error ? err.message : t('source.deleteSourcesFailed', '删除失败'), 'error')
    } finally {
      setBusyAction(null)
    }
  }

  const handleRetryFailed = () => {
    const failedIds = results
      .filter(r => r.statusCategory === 'failed' || r.statusCategory === 'blocked')
      .map(r => r.id)
    if (failedIds.length === 0) {
      onToast(t('source.noFailedSourcesToRetry', '没有失效书源需要重试'), 'info')
      return
    }
    void startCheck(failedIds)
  }

  const handleRetrySingle = (id: string) => {
    void startCheck([id])
  }

  return (
    <Modal
      opened
      onClose={onClose}
      size="xl"
      withCloseButton={false}
      padding="lg"
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" wrap="nowrap" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
          <Group gap="sm" align="center">
            <Icon name="activity" size={20} className={running ? 'spin' : undefined} />
            <Stack gap={2}>
              <Text fw={700} size="lg">{t('source.healthCheckTitle', '书源连通性与健康体检')}</Text>
              <Text size="xs" c="dimmed">
                {running
                  ? t('source.probingHostConnectivity', { time: (durationMs / 1000).toFixed(1), defaultValue: `正在并发探测书源 Host 与入口连通性 (${(durationMs / 1000).toFixed(1)}s)...` })
                  : t('source.healthSummaryDone', { total: stats.total, time: (durationMs / 1000).toFixed(1), defaultValue: `共检测 ${stats.total} 个书源 · 用时 ${(durationMs / 1000).toFixed(1)}s` })}
              </Text>
            </Stack>
          </Group>
          <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" size={16} />
          </ActionIcon>
        </Group>

        <Progress
          value={running ? 100 : progress.total > 0 ? Math.round((progress.checked / progress.total) * 100) : 100}
          animated={running}
          striped={running}
          color={stats.failed > 0 && !running ? 'gold' : 'brand'}
          size="sm"
          radius="xl"
        />

        <Group justify="space-between" align="center" wrap="wrap" gap="sm">
          <Tabs value={activeTab} onChange={value => setActiveTab((value as TabFilter) ?? 'all')} variant="pills">
            <Tabs.List>
              <Tabs.Tab value="all">
                {t('source.allCount', { count: stats.total, defaultValue: `全部 (${stats.total})` })}
              </Tabs.Tab>
              <Tabs.Tab value="valid" color="teal">
                {t('source.statusValid', { count: stats.valid, defaultValue: `正常 (${stats.valid})` })}
              </Tabs.Tab>
              <Tabs.Tab value="slow" color="gold">
                {t('source.statusSlow', { count: stats.slow, defaultValue: `迟缓 (${stats.slow})` })}
              </Tabs.Tab>
              <Tabs.Tab value="failed" color="red">
                {t('source.statusFailed', { count: stats.failed, defaultValue: `失效 (${stats.failed})` })}
              </Tabs.Tab>
            </Tabs.List>
          </Tabs>

          <TextInput
            size="xs"
            leftSection={<Icon name="search" size={14} />}
            placeholder={t('source.searchHealthResults', '搜索检测结果...')}
            value={filterQuery}
            onChange={e => setFilterQuery(e.target.value)}
            style={{ minWidth: 200 }}
          />
        </Group>

        <Group justify="space-between" wrap="wrap" gap="xs">
          <Group gap="xs">
            <Button
              size="xs"
              variant="default"
              leftSection={<Icon name="refresh" size={14} className={running ? 'spin' : ''} />}
              onClick={() => void startCheck()}
              disabled={running || busyAction !== null}
            >
              {running ? t('source.checking', '体检中...') : t('source.recheckAll', '重新全量体检')}
            </Button>
            {stats.failed > 0 && !running && (
              <Button
                size="xs"
                variant="light"
                color="gold"
                onClick={handleRetryFailed}
                disabled={busyAction !== null}
              >
                {t('source.retryFailed', { count: stats.failed, defaultValue: `重试失效项 (${stats.failed})` })}
              </Button>
            )}
          </Group>
          {stats.failed > 0 && (
            <Group gap="xs">
              <Button
                size="xs"
                variant="light"
                color="gray"
                loading={busyAction === 'disable_failed'}
                onClick={() => void handleBatchDisableFailed()}
                disabled={running || busyAction !== null}
              >
                {t('source.disableFailed', { count: stats.failed, defaultValue: `一键停用失效源 (${stats.failed})` })}
              </Button>
              <Button
                size="xs"
                variant="light"
                color="red"
                loading={busyAction === 'delete_failed'}
                onClick={() => void handleBatchDeleteFailed()}
                disabled={running || busyAction !== null}
              >
                {t('source.deleteFailed', { count: stats.failed, defaultValue: `一键删除失效源 (${stats.failed})` })}
              </Button>
            </Group>
          )}
        </Group>

        <ScrollArea.Autosize mah="54vh" offsetScrollbars>
          {filteredResults.length === 0 ? (
            <Text size="sm" c="dimmed" ta="center" py="xl">
              {running ? t('source.probingInProgress', '正在努力探测中...') : t('source.noMatchingHealthResults', '无符合筛选条件的结果')}
            </Text>
          ) : (
            <Stack gap="xs" pr={4}>
              {filteredResults.map(item => {
                const isSlow = item.statusCategory === 'slow'
                const isBlocked = item.statusCategory === 'blocked'
                const isFailed = item.statusCategory === 'failed'

                let badgeColor: 'teal' | 'gold' | 'orange' | 'red' = 'teal'
                let badgeText = t('source.badgeValid', '连通正常')
                if (isSlow) {
                  badgeColor = 'gold'
                  badgeText = t('source.badgeSlow', '响应较慢')
                } else if (isBlocked) {
                  badgeColor = 'orange'
                  badgeText = t('source.badgeRestricted', '访问受限')
                } else if (isFailed) {
                  badgeColor = 'red'
                  badgeText = t('source.badgeFailed', '连接失效')
                }

                return (
                  <Card key={item.id} p="sm" withBorder radius="md">
                    <Group justify="space-between" align="flex-start" wrap="nowrap" gap="sm">
                      <Stack gap={4} style={{ flex: 1, minWidth: 0 }}>
                        <Group gap="xs" wrap="wrap">
                          <Text size="sm" fw={600} truncate>{item.name}</Text>
                          <Badge size="xs" variant="light" color={badgeColor}>{badgeText}</Badge>
                          {item.latencyMs > 0 && (
                            <Badge size="xs" variant="outline" color="gray">{item.latencyMs}ms</Badge>
                          )}
                          {item.statusCode > 0 && (
                            <Badge size="xs" variant="outline" color="gray">HTTP {item.statusCode}</Badge>
                          )}
                        </Group>
                        <Text size="xs" c="dimmed" truncate title={item.id}>{item.id}</Text>
                        {item.error && <Text size="xs" c="red">{item.error}</Text>}
                      </Stack>
                      <Tooltip label={t('source.singleRetest', '单独重测')}>
                        <ActionIcon
                          variant="subtle"
                          color="gray"
                          onClick={() => handleRetrySingle(item.id)}
                          disabled={running}
                          aria-label={t('source.singleRetest', '单独重测')}
                        >
                          <Icon name="refresh" size={14} />
                        </ActionIcon>
                      </Tooltip>
                    </Group>
                  </Card>
                )
              })}
            </Stack>
          )}
        </ScrollArea.Autosize>
      </Stack>
    </Modal>
  )
}
