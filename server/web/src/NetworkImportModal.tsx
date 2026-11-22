import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ActionIcon,
  Alert,
  Badge,
  Button,
  Checkbox,
  Collapse,
  Group,
  Menu,
  Modal,
  Paper,
  Popover,
  ScrollArea,
  Select,
  Stack,
  Text,
  TextInput,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, type ImportResponse, type NetworkImportPreview } from './api'
import { Icon } from './icons'

/** 「不分组」用的哨兵：与真实分组名区分开。 */
const NO_GROUP = ''
/** 「新建分组…」用的哨兵。 */
const NEW_GROUP = '\u0000new'

interface NetworkImportModalProps {
  /**
   * 预填地址。内置浏览器里点书源「更新书源」页的线路时由宿主传入，给了就自动拉取。
   * 书源页直接点「网络导入」时不传，由用户自己填。
   */
  initialUrl?: string
  /**
   * **已经拿到的预览**（本地文件导入用）。
   *
   * 本地 JSON 由前端读出文件原文、交给服务端同一套解析器算出预览后再打开本弹窗，
   * 因此传了这个就**不再发起拉取**，地址行也退化为只读的文件名展示。
   * 票据由预览接口签发，确认时走的仍是同一条 commit 路径。
   */
  initialPreview?: NetworkImportPreview | null
  /** 本地模式下载体名称（文件名），仅用于展示。 */
  localLabel?: string
  /** 可选的目标分组候选（书源页已有的分组）。 */
  groups?: string[]
  onClose: () => void
  /** 导入成功回调（父级据此刷新书源列表）。 */
  onImported?: (result: ImportResponse) => void
  onToast: (message: string, type?: 'info' | 'success' | 'error') => void
}

/**
 * 网络书源导入弹窗（书源页与内置浏览器**共用同一个组件**）。
 *
 * 布局对齐 Legado 手机端的「导入书源」面板：标题 + 自定义源分组 + ⋮ 菜单；
 * 每行 = 勾选框 + 书源名 + 状态标签（新增 / 更新 / 不可导入）+ 圆形详情按钮；
 * 底部 = 「取消全选（n/N）」+ 取消 / 确认。
 *
 * ⚠️ 调用方必须把它挂成**平级分支**，严禁嵌在另一个 `.modal-backdrop` 内部
 * （仓库既有教训：带 `animation`/`transform` 的遮罩会形成层叠上下文，导致幽灵穿透）。
 */
export const NetworkImportModal: React.FC<NetworkImportModalProps> = ({
  initialUrl,
  initialPreview = null,
  localLabel,
  groups = [],
  onClose,
  onImported,
  onToast,
}) => {
  const { t } = useTranslation()
  /** 本地文件模式：预览已经由预览接口算好，本弹窗只负责挑选与确认。 */
  const localMode = initialPreview !== null
  const [url, setUrl] = useState(initialUrl ?? '')
  const [fetching, setFetching] = useState(false)
  const [committing, setCommitting] = useState(false)
  const [preview, setPreview] = useState<NetworkImportPreview | null>(initialPreview)
  const [selected, setSelected] = useState<Set<number>>(
    // 默认全选「可导入」的条目（与手机端一致）；本地模式一进来就按同一规则选好
    () => new Set((initialPreview?.sources ?? []).filter(item => item.status !== 'invalid').map(item => item.index)),
  )
  const [detailIndex, setDetailIndex] = useState<number | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const [groupOpen, setGroupOpen] = useState(false)
  const [groupChoice, setGroupChoice] = useState<string>(NO_GROUP)
  const [newGroupName, setNewGroupName] = useState('')
  /** 已自动拉取过，避免父组件重渲染时反复请求。 */
  const autoFetchedRef = useRef(false)

  const effectiveGroup = groupChoice === NEW_GROUP ? newGroupName.trim() : groupChoice

  const runPreview = useCallback(async (target: string) => {
    const value = target.trim()
    if (!value) {
      onToast(t('source.networkImportUrlRequired', '请填写书源地址'), 'info')
      return
    }
    setFetching(true)
    try {
      const result = await api.previewNetworkImport(value)
      setPreview(result)
      // 默认全选「可导入」的条目（与手机端一致）
      setSelected(new Set(result.sources.filter(item => item.status !== 'invalid').map(item => item.index)))
      setDetailIndex(null)
    } catch (error) {
      setPreview(null)
      setSelected(new Set())
      onToast(error instanceof Error ? error.message : t('source.networkImportFailed', '拉取失败'), 'error')
    } finally {
      setFetching(false)
    }
  }, [onToast, t])

  // 从内置浏览器线路进来时自动拉取一次（**本地文件模式不拉取**：预览已经给了）
  useEffect(() => {
    if (localMode) return
    if (autoFetchedRef.current) return
    if (!initialUrl || !initialUrl.trim()) return
    autoFetchedRef.current = true
    void runPreview(initialUrl)
  }, [initialUrl, localMode, runPreview])

  const selectable = useMemo(
    () => (preview?.sources ?? []).filter(item => item.status !== 'invalid'),
    [preview],
  )

  const toggleOne = (index: number) => {
    setSelected(prev => {
      const next = new Set(prev)
      if (next.has(index)) next.delete(index)
      else next.add(index)
      return next
    })
  }

  const selectAll = () => setSelected(new Set(selectable.map(item => item.index)))
  const clearAll = () => setSelected(new Set())
  const invert = () => setSelected(prev => new Set(selectable.map(i => i.index).filter(index => !prev.has(index))))

  const handleConfirm = async () => {
    if (!preview) return
    const indexes = [...selected].sort((a, b) => a - b)
    if (indexes.length === 0) {
      onToast(t('source.networkImportEmptySelection', '请先勾选要导入的书源'), 'info')
      return
    }
    setCommitting(true)
    try {
      const result = await api.commitNetworkImport(preview.token, indexes, effectiveGroup || null)
      onToast(
        t('source.networkImportDone', {
          imported: result.imported,
          updated: result.updated,
          defaultValue: `导入完成：新增 ${result.imported} 个，更新 ${result.updated} 个`,
        }),
        'success',
      )
      onImported?.(result)
      onClose()
    } catch (error) {
      onToast(error instanceof Error ? error.message : t('source.networkImportCommitFailed', '导入失败'), 'error')
    } finally {
      setCommitting(false)
    }
  }

  const groupLabel = effectiveGroup || t('source.networkImportKeepGroup', '沿用原分组')

  return (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      zIndex={360}
      withCloseButton={false}
      padding="lg"
    >
      <Stack gap="md">
        <Group justify="space-between" align="center" wrap="wrap" gap="xs">
          <Group gap="xs">
            <Icon name="cloudDownload" size={18} />
            <Text fw={700} size="lg">{t('source.networkImportTitle', '导入书源')}</Text>
          </Group>

          <Group gap="xs">
            <Popover
              opened={groupOpen}
              onChange={setGroupOpen}
              position="bottom-end"
              width={290}
              shadow="md"
              withinPortal={false}
              zIndex={380}
            >
              <Popover.Target>
                <Button
                  size="xs"
                  variant={effectiveGroup ? 'light' : 'default'}
                  color={effectiveGroup ? 'brand' : 'gray'}
                  leftSection={<Icon name="folder" size={14} />}
                  onClick={() => { setGroupOpen(open => !open); setMenuOpen(false) }}
                  title={t('source.networkImportCustomGroupHint', '选择本次导入的目标分组')}
                >
                  {t('source.networkImportCustomGroup', '自定义源分组')}
                  {effectiveGroup ? `：${groupLabel}` : ''}
                </Button>
              </Popover.Target>
              <Popover.Dropdown>
                <Stack gap="xs">
                  <Select
                    size="xs"
                    label={t('source.targetGroup', '目标分组')}
                    comboboxProps={{ withinPortal: false }}
                    value={groupChoice}
                    onChange={value => setGroupChoice(value ?? NO_GROUP)}
                    data={[
                      { value: NO_GROUP, label: t('source.networkImportKeepGroup', '沿用原分组') },
                      ...groups.filter(Boolean).map(name => ({ value: name, label: name })),
                      { value: NEW_GROUP, label: t('source.networkImportNewGroup', '新建分组…') },
                    ]}
                  />
                  {groupChoice === NEW_GROUP && (
                    <TextInput
                      size="xs"
                      placeholder={t('source.networkImportGroupNamePlaceholder', '输入新分组名')}
                      value={newGroupName}
                      onChange={event => setNewGroupName(event.target.value)}
                    />
                  )}
                  <Text size="xs" c="dimmed">
                    {t('source.networkImportGroupHint', '不手动选择时，新书源沿用文件分组，已有书源保留当前分组。')}
                  </Text>
                </Stack>
              </Popover.Dropdown>
            </Popover>

            <Menu opened={menuOpen} onChange={setMenuOpen} position="bottom-end" withinPortal={false} zIndex={380}>
              <Menu.Target>
                <ActionIcon variant="subtle" color="gray" aria-label={t('common.more', '更多')}>
                  <Icon name="more" size={16} />
                </ActionIcon>
              </Menu.Target>
              <Menu.Dropdown>
                <Menu.Item leftSection={<Icon name="check" size={14} />} onClick={() => { selectAll(); setMenuOpen(false) }}>
                  {t('source.networkImportSelectAll', '全选')}
                </Menu.Item>
                <Menu.Item leftSection={<Icon name="close" size={14} />} onClick={() => { clearAll(); setMenuOpen(false) }}>
                  {t('source.networkImportDeselectAll', '取消全选')}
                </Menu.Item>
                <Menu.Item leftSection={<Icon name="refresh" size={14} />} onClick={() => { invert(); setMenuOpen(false) }}>
                  {t('source.networkImportInvert', '反选')}
                </Menu.Item>
              </Menu.Dropdown>
            </Menu>

            <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
              <Icon name="close" size={16} />
            </ActionIcon>
          </Group>
        </Group>

        {localMode ? (
          <TextInput
            value={localLabel ?? t('source.localImportLabel', '本地文件')}
            readOnly
            disabled
            leftSection={<Icon name="file" size={15} />}
            aria-label={t('source.localImportLabel', '本地文件')}
          />
        ) : (
          <Group gap="xs" align="flex-start" wrap="nowrap">
            <TextInput
              style={{ flex: 1 }}
              placeholder="https://example.com/book-sources.json"
              value={url}
              leftSection={<Icon name="globe" size={15} />}
              onChange={event => { setUrl(event.target.value); setPreview(null); setSelected(new Set()) }}
              onKeyDown={event => { if (event.key === 'Enter') void runPreview(url) }}
            />
            <Button
              loading={fetching}
              onClick={() => void runPreview(url)}
              leftSection={!fetching ? <Icon name="cloudDownload" size={15} /> : undefined}
            >
              {fetching ? t('source.networkImportFetching', '拉取中…') : t('source.networkImportFetch', '拉取')}
            </Button>
          </Group>
        )}

        {preview && (
          <Stack gap="sm">
            <Alert variant="light" color="brand" p="xs">
              <Text size="xs" fw={500}>
                {t('source.networkImportSummary', {
                  total: preview.total,
                  newCount: preview.newCount,
                  updateCount: preview.updateCount,
                  invalidCount: preview.invalidCount,
                  defaultValue: `共 ${preview.total} 条：新增 ${preview.newCount}，更新 ${preview.updateCount}，不可导入 ${preview.invalidCount}`,
                })}
              </Text>
            </Alert>

            <ScrollArea.Autosize mah={360} offsetScrollbars>
              <Stack gap={6}>
                {preview.sources.map(item => {
                  const invalid = item.status === 'invalid'
                  const checked = selected.has(item.index)
                  const expanded = detailIndex === item.index && !invalid
                  return (
                    <Paper key={item.index} p="xs" withBorder radius="sm" style={{ opacity: invalid ? 0.65 : 1 }}>
                      <Group justify="space-between" wrap="nowrap" gap="xs">
                        <Checkbox
                          checked={checked}
                          disabled={invalid}
                          onChange={() => toggleOne(item.index)}
                          label={<Text size="sm" fw={500} lineClamp={1}>{item.name}</Text>}
                          style={{ flex: 1, minWidth: 0 }}
                        />
                        <Group gap={6} wrap="nowrap">
                          <Badge
                            size="xs"
                            variant="light"
                            color={invalid ? 'red' : item.status === 'update' ? 'blue' : 'teal'}
                          >
                            {invalid
                              ? t('source.networkImportBadgeInvalid', '不可导入')
                              : item.status === 'update'
                                ? t('source.networkImportBadgeUpdate', '更新')
                                : t('source.networkImportBadgeNew', '新增')}
                          </Badge>
                          {invalid ? (
                            <Text size="xs" c="red" maw={140} truncate title={item.reason ?? undefined}>
                              {item.reason}
                            </Text>
                          ) : (
                            <ActionIcon
                              size="sm"
                              variant="subtle"
                              color="gray"
                              title={t('source.networkImportDetail', '查看书源详情')}
                              aria-label={t('source.networkImportDetail', '查看书源详情')}
                              onClick={() => setDetailIndex(detailIndex === item.index ? null : item.index)}
                            >
                              <Icon name="edit" size={14} />
                            </ActionIcon>
                          )}
                        </Group>
                      </Group>
                      <Collapse in={expanded}>
                        <Text size="xs" c="dimmed" mt={6} pl={28} style={{ wordBreak: 'break-all' }}>
                          {t('source.networkImportFieldUrl', '地址')}：{item.url || '—'}
                        </Text>
                      </Collapse>
                    </Paper>
                  )
                })}
              </Stack>
            </ScrollArea.Autosize>

            <Group justify="space-between" align="center">
              <Button
                size="xs"
                variant="light"
                color="gray"
                disabled={selectable.length === 0}
                onClick={selectable.length > 0 && selected.size === selectable.length ? clearAll : selectAll}
              >
                {selectable.length > 0 && selected.size === selectable.length
                  ? t('source.networkImportDeselectAllCount', {
                      selected: selected.size,
                      total: selectable.length,
                      defaultValue: `取消全选（${selected.size}/${selectable.length}）`,
                    })
                  : t('source.networkImportSelectAllCount', {
                      selected: selected.size,
                      total: selectable.length,
                      defaultValue: `全选（${selected.size}/${selectable.length}）`,
                    })}
              </Button>
            </Group>
          </Stack>
        )}

        <Group justify="flex-end" gap="sm" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
          <Button variant="default" onClick={onClose}>
            {t('common.cancel', '取消')}
          </Button>
          <Button
            loading={committing}
            disabled={!preview || committing || fetching}
            onClick={() => void handleConfirm()}
          >
            {committing ? t('common.loading', '处理中…') : t('source.networkImportConfirm', '确认')}
          </Button>
        </Group>
      </Stack>
    </Modal>
  )
}
