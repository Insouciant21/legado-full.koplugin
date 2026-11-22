import { useEffect, useMemo, useState } from 'react'
import {
  Alert,
  Badge,
  Button,
  Checkbox,
  Group,
  Loader,
  Modal,
  Paper,
  ScrollArea,
  Stack,
  Text,
  TextInput,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, SourceSummary, UNGROUPED_SOURCE_GROUP } from './api'
import { Icon } from './icons'

export interface SearchScopePickerModalProps {
  selectedGroups: string[]
  selectedSourceIds: string[]
  onApply: (groups: string[], sourceIds: string[]) => void
  onClose: () => void
}

export function selectedGroupForSource(item: Pick<SourceSummary, 'group'>, selectedGroups: string[]) {
  const group = item.group?.trim() || UNGROUPED_SOURCE_GROUP
  return selectedGroups.find(selected => selected.toLowerCase() === group.toLowerCase())
}

export function expandGroupWithoutSource(
  selectedGroups: string[],
  selectedSourceIds: string[],
  group: string,
  excludedSourceId: string,
  groupMemberIds: string[],
) {
  return {
    groups: selectedGroups.filter(item => item !== group),
    sourceIds: [...new Set([
      ...selectedSourceIds.filter(id => id !== excludedSourceId),
      ...groupMemberIds.filter(id => id !== excludedSourceId),
    ])],
  }
}

export function SearchScopePickerModal({
  selectedGroups,
  selectedSourceIds,
  onApply,
  onClose,
}: SearchScopePickerModalProps) {
  const { t } = useTranslation()
  const [draftGroups, setDraftGroups] = useState<string[]>(selectedGroups)
  const [draftSourceIds, setDraftSourceIds] = useState<string[]>(selectedSourceIds)
  const [query, setQuery] = useState('')
  const [items, setItems] = useState<SourceSummary[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [retry, setRetry] = useState(0)
  const [pendingSourceId, setPendingSourceId] = useState<string | null>(null)

  useEffect(() => {
    const trimmed = query.trim()
    const controller = new AbortController()
    setLoading(true)
    setError('')
    void api.sourcePicker(trimmed, [], controller.signal)
      .then(result => setItems(result.items))
      .catch(err => {
        if (controller.signal.aborted) return
        setItems([])
        setError(err instanceof Error ? err.message : t('search.scopePickerLoadFailed', '书源查询失败'))
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false)
      })
    return () => controller.abort()
  }, [query, retry, t])

  const selectedSet = useMemo(() => new Set(draftSourceIds), [draftSourceIds])

  const toggleSource = async (item: SourceSummary) => {
    const selectedGroup = selectedGroupForSource(item, draftGroups)
    if (!selectedGroup) {
      setDraftSourceIds(previous => previous.includes(item.id)
        ? previous.filter(id => id !== item.id)
        : [...previous, item.id])
      return
    }

    setPendingSourceId(item.id)
    setError('')
    try {
      const result = await api.sourcePicker('', [selectedGroup])
      const next = expandGroupWithoutSource(
        draftGroups,
        draftSourceIds,
        selectedGroup,
        item.id,
        result.items.map(source => source.id),
      )
      setDraftGroups(next.groups)
      setDraftSourceIds(next.sourceIds)
    } catch (err) {
      setError(err instanceof Error ? err.message : t('search.scopePickerLoadFailed', '书源查询失败'))
    } finally {
      setPendingSourceId(null)
    }
  }

  const clear = () => {
    setDraftGroups([])
    setDraftSourceIds([])
  }

  return (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      title={
        <Stack gap={2}>
          <Text fw={700} size="lg">{t('search.scopePickerTitle', '选择搜索范围')}</Text>
          <Text size="xs" c="dimmed">{t('search.scopePickerDesc', '可选择一个或多个书源，并与外部分组组合搜索')}</Text>
        </Stack>
      }
    >
      <Stack gap="md">
        <TextInput
          data-autofocus
          leftSection={<Icon name="search" size={15} />}
          value={query}
          onChange={event => setQuery(event.target.value)}
          placeholder={t('search.scopePickerSearchPlaceholder', '输入书源名称、地址或分组名称')}
          aria-label={t('search.scopePickerSearchPlaceholder', '输入书源名称、地址或分组名称')}
        />

        <ScrollArea h={340} offsetScrollbars>
          <Stack gap="xs" aria-live="polite">
            {loading && (
              <Group justify="center" py="xl">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">{t('common.loading', '加载中...')}</Text>
              </Group>
            )}
            {!loading && error && (
              <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
                <Group justify="space-between">
                  <Text size="sm">{error}</Text>
                  <Button size="xs" variant="light" color="red" onClick={() => setRetry(value => value + 1)}>
                    {t('common.retry', '重试')}
                  </Button>
                </Group>
              </Alert>
            )}
            {!loading && !error && items.length === 0 && (
              <Text size="sm" c="dimmed" ta="center" py="xl">
                {t('search.scopePickerNoSources', '没有匹配的书源')}
              </Text>
            )}
            {!loading && !error && items.map(item => {
              const checked = selectedSet.has(item.id) || selectedGroupForSource(item, draftGroups) !== undefined
              return (
                <Paper
                  key={item.id}
                  p="xs"
                  style={{
                    cursor: pendingSourceId ? 'wait' : 'pointer',
                    borderColor: checked ? 'var(--accent)' : undefined,
                    background: checked ? 'var(--accent-soft)' : undefined,
                  }}
                  onClick={() => {
                    if (pendingSourceId === null) void toggleSource(item)
                  }}
                >
                  <Group gap="sm" wrap="nowrap">
                    <Checkbox
                      checked={checked}
                      data-source-id={item.id}
                      disabled={pendingSourceId !== null}
                      onChange={() => void toggleSource(item)}
                      onClick={event => event.stopPropagation()}
                    />
                    <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
                      <Group gap="xs" wrap="nowrap">
                        <Text size="sm" fw={600} truncate>{item.name}</Text>
                        <Badge size="xs" variant="light" color="gray">
                          {item.group || t('search.scopeUngrouped', '未分组')}
                        </Badge>
                      </Group>
                      <Text size="xs" c="dimmed" truncate>{item.url}</Text>
                    </Stack>
                  </Group>
                </Paper>
              )
            })}
          </Stack>
        </ScrollArea>

        <Group justify="space-between" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
          <Text size="xs" c="dimmed">
            {t('search.scopePickerSelected', '已选 {{groups}} 个分组 + {{sources}} 个书源', { groups: draftGroups.length, sources: draftSourceIds.length })}
          </Text>
          <Group gap="xs">
            <Button variant="subtle" color="gray" disabled={pendingSourceId !== null} onClick={clear}>
              {t('common.clear', '清空')}
            </Button>
            <Button variant="default" onClick={onClose}>
              {t('common.cancel', '取消')}
            </Button>
            <Button disabled={pendingSourceId !== null} onClick={() => { onApply(draftGroups, draftSourceIds); onClose() }}>
              {t('common.apply', '应用范围')}
            </Button>
          </Group>
        </Group>
      </Stack>
    </Modal>
  )
}
