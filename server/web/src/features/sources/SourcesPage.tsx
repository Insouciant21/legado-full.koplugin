import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Alert,
  Badge,
  Box,
  Button,
  Center,
  Checkbox,
  Grid,
  Group,
  Menu,
  Paper,
  ScrollArea,
  Select,
  Stack,
  Text,
  Textarea,
  TextInput,
  Title,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, NetworkImportPreview, SourceGroupSummary, SourceRecord, SourceSummary, UNGROUPED_SOURCE_GROUP } from '../../api'
import { Icon } from '../../icons'
import { NetworkImportModal } from '../../NetworkImportModal'
import { SourceGroupManagerModal } from '../../SourceGroupManagerModal'
import { SourceHealthModal } from '../../SourceHealthModal'
import { SourceLoginModal } from '../../SourceLoginModal'
import { toast } from '../../Toast'

function SourceEditor({
  selected,
  onSaved,
  onOpenLogin,
}: {
  selected: SourceSummary | null
  onSaved: () => void
  onOpenLogin?: (source: SourceSummary) => void
}) {
  const { t } = useTranslation()
  const [record, setRecord] = useState<SourceRecord | null>(null); const [text, setText] = useState(''); const [status, setStatus] = useState<{ message: string; isError: boolean } | null>(null)
  useEffect(() => {
    if (!selected) { setRecord(null); setText(''); setStatus(null); return }
    let cancelled = false
    setRecord(null)
    setStatus(null)
    void api.source(selected.id).then(value => {
      if (cancelled) return
      setRecord(value)
      setText(value.json)
      setStatus(null)
    }).catch(error => {
      if (cancelled) return
      setStatus({ message: error.message, isError: true })
    })
    return () => { cancelled = true }
  }, [selected?.id])
  const save = async () => {
    if (!record || !selected || record.id !== selected.id) return
    try {
      const next = await api.save(selected.id, text, record.version)
      setRecord(next)
      setStatus({ message: t('source.saved', '已保存'), isError: false })
      onSaved()
    } catch (error) {
      setStatus({ message: error instanceof Error ? error.message : t('source.saveFailed', '保存失败'), isError: true })
    }
  }
  const validate = async () => { if (!selected) return; try { const result = await api.validate(selected.id); setStatus({ message: result.valid ? result.warnings.join('；') || t('source.validatePass', '结构校验通过') : result.errors.join('；'), isError: !result.valid }) } catch (error) { setStatus({ message: error instanceof Error ? error.message : t('source.validateFailed', '校验失败'), isError: true }) } }
  if (!selected) {
    return (
      <Paper p="xl" withBorder radius="lg" mih={420}>
        <Center h="100%" mih={340}>
          <Stack align="center" gap="xs" ta="center">
            <Icon name="book" size={32} />
            <Title order={4}>{t('source.selectOneSource', '选择一个书源')}</Title>
            <Text size="sm" c="dimmed">{t('source.selectOneSourceDesc', '从列表选择书源，或导入一个 JSON 文件。')}</Text>
          </Stack>
        </Center>
      </Paper>
    )
  }
  return (
    <Paper p="md" withBorder radius="lg">
      <Stack gap="sm">
        <Group justify="space-between" align="flex-start" wrap="wrap" gap="sm">
          <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
            <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
              {t('source.sourceEditKicker', '书源编辑')}
            </Text>
            <Group gap="xs" wrap="wrap">
              <Title order={4}>{selected.name}</Title>
              {selected.hasLogin && (
                <Badge size="sm" variant="light" color="brand" title={t('source.supportLoginAuth', '支持登录鉴权')}>
                  {t('source.loginBadge', '登录')}
                </Badge>
              )}
            </Group>
            <Text size="xs" c="dimmed" truncate style={{ fontFamily: 'var(--mantine-font-family-monospace)' }}>
              {selected.url}
            </Text>
          </Stack>
          <Group gap="xs">
            {selected.hasLogin && (
              <Button
                size="xs"
                variant="light"
                leftSection={<Icon name="key" size={14} />}
                onClick={() => onOpenLogin?.(selected)}
              >
                {t('source.loginButton', '登录')}
              </Button>
            )}
            <Button size="xs" variant="default" onClick={() => void validate()}>
              {t('source.validateButton', '校验')}
            </Button>
            <Button size="xs" onClick={() => void save()}>
              {t('source.saveButton', '保存')}
            </Button>
          </Group>
        </Group>

        <Textarea
          aria-label={t('source.editorAria', '书源 JSON 编辑器')}
          value={text}
          onChange={event => setText(event.target.value)}
          spellCheck={false}
          rows={22}
          styles={{
            input: {
              fontFamily: 'var(--mantine-font-family-monospace)',
              fontSize: 12,
              lineHeight: 1.55,
            },
          }}
        />

        {status && (
          <Alert color={status.isError ? 'red' : 'teal'} variant="light" p="xs">
            <Text size="xs">{status.message}</Text>
          </Alert>
        )}
      </Stack>
    </Paper>
  )
}

export default function SourcesPage({ selected, onSelect, onSourcesChange }: { selected: SourceSummary | null; onSelect: (source: SourceSummary | null) => void; onSourcesChange: (sources: SourceSummary[]) => void }) {
  const { t } = useTranslation()
  const [sources, setSources] = useState<SourceSummary[]>([])
  /** 服务端聚合的分组概览（名字 + 总数 + 已启用数），供「分组管理」面板使用。 */
  const [groupSummaries, setGroupSummaries] = useState<SourceGroupSummary[]>([])
  const [query, setQuery] = useState('')
  const [groupFilter, setGroupFilter] = useState('')
  const [notice, setNotice] = useState('')
  const [importing, setImporting] = useState(false)
  const [isBatchMode, setIsBatchMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [showHealthModal, setShowHealthModal] = useState(false)
  const [showGroupManager, setShowGroupManager] = useState(false)
  const [busyBatch, setBusyBatch] = useState(false)
  const [loginModalSource, setLoginModalSource] = useState<SourceSummary | null>(null)
  /** 网络导入弹窗是否打开（与「导入 JSON」并列的另一种导入方式）。 */
  const [showNetworkImport, setShowNetworkImport] = useState(false)
  const importFileInputRef = useRef<HTMLInputElement>(null)
  /**
   * 本地文件导入时，预览接口返回的结果与文件名。
   *
   * 有值时弹窗走「本地模式」：不再拉取，直接把这份预览列出来让用户挑。
   */
  const [localImportPreview, setLocalImportPreview] = useState<NetworkImportPreview | null>(null)
  const [localImportLabel, setLocalImportLabel] = useState<string>('')

  const load = useCallback(async () => {
    try {
      const values = await api.sources(query)
      setSources(values)
      onSourcesChange(values)
      // 分组概览由服务端聚合（含「已启用」数）；它只服务于「分组管理」面板，失败不该影响书源列表
      void api.sourceGroups().then(setGroupSummaries).catch(() => undefined)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : t('source.cannotLoad', '无法载入书源'))
    }
  }, [onSourcesChange, query])

  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 180)
    return () => window.clearTimeout(timer)
  }, [load])

  const allGroups = useMemo(() => {
    const set = new Set<string>()
    for (const s of sources) {
      if (s.group && s.group.trim()) set.add(s.group.trim())
    }
    return Array.from(set).sort()
  }, [sources])
  const enabledSourceCount = sources.filter(source => source.enabled).length
  const loginSourceCount = sources.filter(source => source.hasLogin).length

  const filteredSources = useMemo(() => {
    return sources.filter(source => {
      if (groupFilter) {
        if (groupFilter === UNGROUPED_SOURCE_GROUP && source.group) return false
        if (groupFilter !== UNGROUPED_SOURCE_GROUP && (source.group ?? '') !== groupFilter) return false
      }
      if (query) {
        const q = query.toLowerCase()
        return source.name.toLowerCase().includes(q) || source.url.toLowerCase().includes(q) || (source.group ?? '').toLowerCase().includes(q)
      }
      return true
    })
  }, [sources, groupFilter, query])

  const toggleSelect = (id: string) => {
    setSelectedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const handleSelectAll = () => {
    setSelectedIds(new Set(filteredSources.map(s => s.id)))
  }

  const handleClearAll = () => {
    setSelectedIds(new Set())
  }

  const handleInvertSelection = () => {
    setSelectedIds(prev => {
      const next = new Set<string>()
      for (const s of filteredSources) {
        if (!prev.has(s.id)) next.add(s.id)
      }
      return next
    })
  }

  const handleBatchEnable = async () => {
    if (selectedIds.size === 0) return
    setBusyBatch(true)
    try {
      const resp = await api.batchSources('enable', Array.from(selectedIds))
      toast.success(t('source.batchEnableSuccess', '已批量启用 {{count}} 个书源', { count: resp.affected }))
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.enableFailed', '启用失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  const handleBatchDisable = async () => {
    if (selectedIds.size === 0) return
    setBusyBatch(true)
    try {
      const resp = await api.batchSources('disable', Array.from(selectedIds))
      toast.success(t('source.batchDisableSuccess', '已批量停用 {{count}} 个书源', { count: resp.affected }))
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.disableFailed', '停用失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  const handleBatchDelete = async () => {
    if (selectedIds.size === 0) return
    const selectedSources = sources.filter(s => selectedIds.has(s.id))
    const namesSummary = selectedSources.slice(0, 3).map(s => s.name).join('、') + (selectedSources.length > 3 ? t('source.etcCount', ' 等共 {{count}} 项', { count: selectedSources.length }) : '')
    if (!confirm(t('source.batchDeleteConfirm', '确定要彻底删除选中的 {{count}} 个书源吗？\n（{{names}}）\n删除后不可恢复！', { count: selectedIds.size, names: namesSummary }))) return
    setBusyBatch(true)
    try {
      const resp = await api.batchSources('delete', Array.from(selectedIds))
      toast.success(t('source.batchDeleteSuccess', '已删除 {{count}} 个书源', { count: resp.affected }))
      setSelectedIds(new Set())
      if (selected && selectedIds.has(selected.id)) {
        onSelect(null)
      }
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.deleteFailed', '删除失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  const handleBatchExport = async () => {
    if (selectedIds.size === 0) return
    setBusyBatch(true)
    try {
      const exportStrings = await api.exportSources(Array.from(selectedIds))
      const parsedList = exportStrings.map(str => {
        try { return JSON.parse(str) } catch { return null }
      }).filter(Boolean)
      const blob = new Blob([JSON.stringify(parsedList, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `legado_sources_export_${new Date().toISOString().slice(0, 10)}.json`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
      toast.success(t('source.exportSuccess', '已成功导出 {{count}} 个书源', { count: parsedList.length }))
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.exportFailed', '导出失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  /**
   * 本地 JSON 导入：**先出预览列表，再由用户挑**（与网络导入同一个弹窗、同一套票据）。
   *
   * 解析与「新增 / 更新 / 不可导入」的判定都交给服务端的**同一个解析器**，
   * 前端只负责把文件原文读出来 —— 这样本地与网络两条路的规则不会漂移。
   */
  const importSources = async (file: File | undefined) => {
    if (!file) return
    setImporting(true)
    try {
      const rawText = await file.text()
      const result = await api.previewLocalSourceJson(rawText, file.name)
      setLocalImportPreview(result)
      setLocalImportLabel(file.name)
      setShowNetworkImport(true)
    } catch (error) {
      const message = error instanceof Error ? error.message : t('source.invalidFormat', '书源格式无效')
      toast.error(message)
      setNotice(t('source.importFailedPrefix', '导入失败：{{reason}}', { reason: message }))
    } finally {
      setImporting(false)
    }
  }

  const remove = async () => {
    if (!selected || !confirm(t('source.deleteSingleConfirm', '删除“{{name}}”？', { name: selected.name }))) return
    try {
      await api.remove(selected.id)
      onSelect(null)
      await load()
    } catch (error) {
      setNotice(error instanceof Error ? error.message : t('source.deleteFailed', '删除失败'))
    }
  }

  return (
    <Box component="main" pb={isBatchMode ? 88 : 0}>
      <Grid gutter="md" align="flex-start">
        <Grid.Col span={{ base: 12, md: 4 }}>
          <Paper p="md" withBorder radius="lg">
            <Stack gap="sm">
              <Group justify="space-between" align="center" wrap="nowrap">
                <Group gap="xs">
                  <Text fw={700} size="md">{t('source.libraryTitle', '书源库')}</Text>
                  <Badge size="sm" variant="light" color="gray">
                    {filteredSources.length} / {sources.length}
                  </Badge>
                </Group>
                <input
                  ref={importFileInputRef}
                  type="file"
                  accept="application/json,.json,text/plain,.txt,*"
                  style={{ display: 'none' }}
                  onChange={event => {
                    const file = event.target.files?.[0]
                    if (file) void importSources(file)
                    event.target.value = ''
                  }}
                />
                <Menu position="bottom-end" withinPortal>
                  <Menu.Target>
                    <Button
                      size="xs"
                      variant="light"
                      loading={importing}
                      leftSection={<Icon name="upload" size={14} />}
                      rightSection={<Icon name="chevronDown" size={13} />}
                    >
                      导入书源
                    </Button>
                  </Menu.Target>
                  <Menu.Dropdown>
                    <Menu.Item
                      leftSection={<Icon name="upload" size={14} />}
                      onClick={() => importFileInputRef.current?.click()}
                    >
                      {importing ? t('common.loading', '导入中...') : t('source.importJson', '导入 JSON')}
                    </Menu.Item>
                    <Menu.Item
                      leftSection={<Icon name="cloudDownload" size={14} />}
                      onClick={() => setShowNetworkImport(true)}
                    >
                      {t('source.networkImport', '网络导入')}
                    </Menu.Item>
                  </Menu.Dropdown>
                </Menu>
              </Group>

              <Text size="xs" c="dimmed">集中维护书源规则、分组与登录状态</Text>

              <Group gap={6} wrap="wrap">
                <Button
                  size="xs"
                  variant="default"
                  leftSection={<Icon name="activity" size={14} />}
                  title={t('source.healthCheck', '书源连通性体检')}
                  onClick={() => setShowHealthModal(true)}
                >
                  {t('source.healthCheck', '体检')}
                </Button>
                <Button
                  size="xs"
                  variant={isBatchMode ? 'filled' : 'default'}
                  leftSection={<Icon name="list" size={14} />}
                  title={t('source.batchManageTooltip', '批量启用 / 停用 / 导出 / 删除书源')}
                  onClick={() => {
                    setIsBatchMode(prev => !prev)
                    setSelectedIds(new Set())
                  }}
                >
                  {isBatchMode ? t('common.ok', '退出批量') : t('source.batchManage', '批量管理')}
                </Button>
                <Button
                  size="xs"
                  variant="default"
                  leftSection={<Icon name="folder" size={14} />}
                  title={t('source.groupManager', '书源分组管理')}
                  onClick={() => setShowGroupManager(true)}
                >
                  {t('source.groupManager', '分组管理')}
                </Button>
              </Group>

              {allGroups.length > 0 && (
                <Select
                  size="xs"
                  aria-label={t('source.groupManager', '按分组筛选书源')}
                  value={groupFilter}
                  onChange={value => setGroupFilter(value ?? '')}
                  data={[
                    { value: '', label: `${t('search.scopeAll', '全部分组')} (${sources.length})` },
                    ...allGroups.map(g => ({
                      value: g,
                      label: `${g} (${sources.filter(s => s.group === g).length})`,
                    })),
                    {
                      value: UNGROUPED_SOURCE_GROUP,
                      label: `${t('search.scopeUngrouped', '未分组')} (${sources.filter(s => !s.group).length})`,
                    },
                  ]}
                />
              )}

              <TextInput
                size="xs"
                leftSection={<Icon name="search" size={14} />}
                placeholder={t('source.filterSourcesPlaceholder', '筛选书源')}
                value={query}
                onChange={event => setQuery(event.target.value)}
              />

              {notice && (
                <Alert color="red" variant="light" p="xs">
                  <Text size="xs">{notice}</Text>
                </Alert>
              )}

              <ScrollArea h={{ base: 340, md: 'calc(100vh - 370px)' }} offsetScrollbars>
                <Stack gap={6} pr={4} component="nav">
                  {filteredSources.map(source => {
                    const isChecked = selectedIds.has(source.id)
                    const isCurrent = selected?.id === source.id

                    return (
                      <Paper
                        key={source.id}
                        component="div"
                        role="button"
                        tabIndex={0}
                        p="xs"
                        withBorder
                        radius="sm"
                        onClick={() => (isBatchMode ? toggleSelect(source.id) : onSelect(source))}
                        onKeyDown={e => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault()
                            if (isBatchMode) toggleSelect(source.id)
                            else onSelect(source)
                          }
                        }}
                        style={{
                          cursor: 'pointer',
                          textAlign: 'left',
                          borderColor: isChecked || isCurrent ? 'var(--accent)' : undefined,
                          background: isChecked || isCurrent ? 'var(--accent-soft)' : undefined,
                        }}
                      >
                        <Group gap="xs" wrap="nowrap" align="center">
                          {isBatchMode && (
                            <Checkbox
                              size="xs"
                              checked={isChecked}
                              onChange={() => toggleSelect(source.id)}
                              onClick={e => e.stopPropagation()}
                            />
                          )}
                          <Stack gap={2} style={{ minWidth: 0, flex: 1 }}>
                            <Group gap={6} wrap="nowrap">
                              <Text size="sm" fw={isCurrent ? 700 : 500} truncate style={{ flex: 1, minWidth: 0 }}>
                                {source.name}
                              </Text>
                              {!source.enabled && (
                                <Badge size="xs" variant="light" color="gray">
                                  {t('common.disabled', '已停用')}
                                </Badge>
                              )}
                              {source.hasLogin && (
                                <Badge size="xs" variant="light" color="brand" title={t('source.supportLoginAuth', '支持登录鉴权')}>
                                  {t('source.loginBadge', '登录')}
                                </Badge>
                              )}
                            </Group>
                            <Text size="xs" c="dimmed" truncate>
                              {source.group || (source.isJsSource ? t('source.jsSource', 'JS 书源') : t('source.normalSource', '书源'))}
                            </Text>
                          </Stack>
                        </Group>
                      </Paper>
                    )
                  })}
                </Stack>
              </ScrollArea>
            </Stack>
          </Paper>
        </Grid.Col>

        <Grid.Col span={{ base: 12, md: 8 }}>
          <Stack gap="md">
            <Paper p="md" withBorder radius="lg">
              <Group justify="space-between" align="center" wrap="wrap" gap="md">
                <Stack gap={2}>
                  <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.8}>
                    {t('login.brand', '阅读服务器')}
                  </Text>
                  <Title order={2}>{t('source.headerTitle', '书源管理')}</Title>
                  <Text size="sm" c="dimmed">{t('source.headerSubtitle', '导入、校验与维护你的阅读来源。')}</Text>
                </Stack>

                <Group gap="sm" align="center" wrap="wrap">
                  <Group gap="xs" aria-label="书源概览">
                    <Badge size="lg" variant="light" color="brand">{enabledSourceCount} 已启用</Badge>
                    <Badge size="lg" variant="light" color="gray">{allGroups.length} 分组</Badge>
                    <Badge size="lg" variant="light" color="gold">{loginSourceCount} 可登录</Badge>
                  </Group>
                  {selected && (
                    <Button
                      size="xs"
                      color="red"
                      variant="light"
                      leftSection={<Icon name="trash" size={14} />}
                      onClick={() => void remove()}
                    >
                      {t('source.deleteSource', '删除书源')}
                    </Button>
                  )}
                </Group>
              </Group>
            </Paper>

            <SourceEditor
              key={selected?.id ?? 'none'}
              selected={selected}
              onSaved={() => void load()}
              onOpenLogin={source => setLoginModalSource(source)}
            />
          </Stack>
        </Grid.Col>
      </Grid>

      {/* Floating Batch Action Bar */}
      {isBatchMode && (
        <Paper
          p="sm"
          withBorder
          radius="lg"
          className="legado-batch-affix"
          aria-label={t('source.batchToolbarAria', '书源批量操作工具栏')}
        >
          <Group justify="space-between" align="center" wrap="wrap" gap="sm">
            <Group gap="xs" wrap="wrap">
              <Badge variant="filled" color="brand">
                {t('source.selectedCount', '已选 {{count}} / {{total}}', {
                  count: selectedIds.size,
                  total: filteredSources.length,
                })}
              </Badge>
              <Button size="compact-xs" variant="subtle" onClick={handleSelectAll}>
                {t('shelf.selectAll', '全选')}
              </Button>
              <Button size="compact-xs" variant="subtle" onClick={handleClearAll}>
                {t('source.deselectAll', '全不选')}
              </Button>
              <Button size="compact-xs" variant="subtle" onClick={handleInvertSelection}>
                {t('common.invertSelect', '反选')}
              </Button>
            </Group>
            <Group gap="xs" wrap="wrap">
              <Button size="xs" variant="default" disabled={selectedIds.size === 0 || busyBatch} onClick={() => void handleBatchEnable()}>
                {t('source.batchEnable', '批量启用')}
              </Button>
              <Button size="xs" variant="default" disabled={selectedIds.size === 0 || busyBatch} onClick={() => void handleBatchDisable()}>
                {t('source.batchDisable', '批量停用')}
              </Button>
              <Button size="xs" variant="default" disabled={selectedIds.size === 0 || busyBatch} onClick={() => void handleBatchExport()}>
                {t('source.batchExport', '导出选中')}
              </Button>
              <Button size="xs" color="red" variant="light" disabled={selectedIds.size === 0 || busyBatch} onClick={() => void handleBatchDelete()}>
                {t('source.batchDelete', '批量删除')}
              </Button>
              <Button
                size="xs"
                onClick={() => {
                  setIsBatchMode(false)
                  setSelectedIds(new Set())
                }}
              >
                {t('common.ok', '完成')}
              </Button>
            </Group>
          </Group>
        </Paper>
      )}

      {showHealthModal && (
        <SourceHealthModal
          sources={sources}
          onClose={() => setShowHealthModal(false)}
          onSourcesChange={() => void load()}
          onToast={(msg, type) => {
            if (type === 'error') toast.error(msg)
            else if (type === 'success') toast.success(msg)
            else toast.info(msg)
          }}
        />
      )}

      {showGroupManager && (
        <SourceGroupManagerModal
          groups={groupSummaries}
          onChanged={() => void load()}
          onClose={() => setShowGroupManager(false)}
        />
      )}

      {loginModalSource && (
        <SourceLoginModal
          sourceId={loginModalSource.id}
          sourceName={loginModalSource.name}
          onClose={() => setLoginModalSource(null)}
          onToast={(msg, type) => {
            if (type === 'error') toast.error(msg)
            else if (type === 'success') toast.success(msg)
            else toast.info(msg)
          }}
        />
      )}

      {/* 导入弹窗：与上面的弹窗**平级**挂载（严禁嵌套 backdrop，见仓库弹窗架构约定）。
          网络导入与本地 JSON 导入共用它 —— 本地模式由 localImportPreview 提供已算好的预览。 */}
      {showNetworkImport && (
        <NetworkImportModal
          groups={allGroups}
          initialPreview={localImportPreview}
          localLabel={localImportLabel}
          onClose={() => { setShowNetworkImport(false); setLocalImportPreview(null); setLocalImportLabel('') }}
          onImported={() => { void load() }}
          onToast={(msg, type) => {
            if (type === 'error') toast.error(msg)
            else if (type === 'success') toast.success(msg)
            else toast.info(msg)
          }}
        />
      )}
    </Box>
  )
}
