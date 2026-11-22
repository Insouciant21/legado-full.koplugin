import React, { useCallback, useEffect, useMemo, useState } from 'react'
import {
  ActionIcon,
  Avatar,
  Badge,
  Box,
  Button,
  Checkbox,
  Divider,
  Group,
  Modal,
  Paper,
  ScrollArea,
  Select,
  Stack,
  Text,
  TextInput,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { i18n } from './i18n'
import { api, SourceGroupSummary, SourceSummary, UNGROUPED_SOURCE_GROUP } from './api'
import { Icon } from './icons'
import { toast } from './Toast'

/**
 * 目标分组的取值：`__new__` 表示「新建分组」，其余为已有分组名。
 *
 * 选了新建但没填名字时返回空值；提交路径始终复用这一判定。
 */
export const NEW_GROUP_OPTION = '__new__'

export function resolveTargetGroup(target: string, newGroupName: string): string | null {
  const name = (target === NEW_GROUP_OPTION ? newGroupName : target).trim()
  if (!name || name.toLowerCase() === UNGROUPED_SOURCE_GROUP.toLowerCase()) return null
  return name
}

/**
 * 删除分组的确认文案。
 *
 * 统一生成「**只删分组，不删书源**」的确认文案。
 */
export function groupDeleteConfirmMessage(
  group: SourceGroupSummary,
  t: (key: string, options?: any) => string = (k, opt) => String(i18n.t(k, opt as any))
): string {
  return t('source.deleteGroupConfirm', {
    name: group.name,
    count: group.sourceCount,
    defaultValue: `删除分组「${group.name}」？\n组内 ${group.sourceCount} 个书源不会被删除，只会变成「未分组」。`,
  })
}

/**
 * 分组卡片左侧的首字标记。
 *
 * 空名兜底成空串；使用 Array.from 安全提取首个 Unicode 代码点，防止 Emoji 代理对截断导致乱码。
 */
export function groupInitial(name: string): string {
  const trimmed = name.trim()
  return trimmed ? (Array.from(trimmed)[0]?.toUpperCase() ?? '') : ''
}

interface SourceGroupManagerModalProps {
  /** 当前分组列表（弹窗自己也会刷新一份）。 */
  groups: SourceGroupSummary[]
  /** 任何改动后通知外层刷新书源列表与分组列表。 */
  onChanged: () => void | Promise<void>
  onClose: () => void
}

/**
 * 「分组管理」：书源分组的**唯一**管理入口（从批量管理里独立出来）。
 *
 * 三件事：看分组 → 改分组（重命名 / 删除）→ 批量勾选书源加入分组。
 *
 * ## 视觉与交互刻意对齐「书架分组管理」（`GroupManageModal`）
 * 复用同一套 `group-manage-*` 骨架类：同样的弹窗外壳、`section-kicker` 标题、行内改名
 * （`group-item-editing` + ✓/✕ 图标按钮）、行右侧图标操作区、底部 `group-manage-footer`。
 * 反馈一律走 `toast`（与书架分组删除/改名一致），不再另画一条提示条。
 *
 * ## 行为上的三点硬约束
 * - **不自动分组**：勾选书源后必须显式选目标分组（或填新组名）才会写入；
 * - 书源列表在弹窗内单独拉**全量**（带自己的筛选框）：外层 `sources` 可能正被书源页的筛选框过滤；
 * - 分组是书源上的字符串，所以没有「先建空分组」这一步：源全部移走后分组自然消失。
 */
export function SourceGroupManagerModal({ groups, onChanged, onClose }: SourceGroupManagerModalProps) {
  const { t } = useTranslation()
  const [localGroups, setLocalGroups] = useState<SourceGroupSummary[]>(groups)
  const [sources, setSources] = useState<SourceSummary[]>([])
  const [query, setQuery] = useState('')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [target, setTarget] = useState('')
  const [newGroupName, setNewGroupName] = useState('')
  const [editingGroup, setEditingGroup] = useState<string | null>(null)
  const [editingName, setEditingName] = useState('')
  const [busy, setBusy] = useState(false)

  const reload = useCallback(async () => {
    const [nextGroups, nextSources] = await Promise.all([api.sourceGroups(), api.sources()])
    setLocalGroups(nextGroups)
    setSources(nextSources)
  }, [])

  useEffect(() => {
    void reload().catch(error => toast.error(error instanceof Error ? error.message : t('source.loadGroupsFailed', '无法载入分组信息')))
  }, [reload, t])

  const visibleSources = useMemo(() => {
    const q = query.trim().toLowerCase()
    const matched = q
      ? sources.filter(source =>
        source.name.toLowerCase().includes(q)
        || source.url.toLowerCase().includes(q)
        || (source.group ?? '').toLowerCase().includes(q))
      : sources
    // 未分组的排在前面：分组管理里最常干的事就是把没归类的源归进去
    return [...matched].sort((a, b) => {
      const aGrouped = a.group ? 1 : 0
      const bGrouped = b.group ? 1 : 0
      if (aGrouped !== bGrouped) return aGrouped - bGrouped
      return a.name.localeCompare(b.name, 'zh-Hans-CN')
    })
  }, [sources, query])

  const toggleSelect = (id: string) => {
    setSelectedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const selectAllVisible = () => setSelectedIds(new Set(visibleSources.map(source => source.id)))
  const clearSelection = () => setSelectedIds(new Set())
  const invertSelection = () => setSelectedIds(prev => new Set(visibleSources.filter(s => !prev.has(s.id)).map(s => s.id)))

  const applyGroup = async (group: string | null) => {
    if (selectedIds.size === 0) {
      toast.info(t('source.selectSourcesFirst', '请先勾选要归类的书源'))
      return
    }
    setBusy(true)
    try {
      const resp = await api.batchSources('set_group', Array.from(selectedIds), group ?? undefined)
      toast.success(t('source.updatedGroupsSuccess', { count: resp.affected, defaultValue: `已更新 ${resp.affected} 个书源的分组` }))
      setSelectedIds(new Set())
      if (target === NEW_GROUP_OPTION && group) setTarget(group)
      setNewGroupName('')
      await reload()
      await onChanged()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('source.modifyGroupFailed', '修改分组失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleAddToGroup = () => {
    const rawName = (target === NEW_GROUP_OPTION ? newGroupName : target).trim()
    if (rawName.toLowerCase() === UNGROUPED_SOURCE_GROUP.toLowerCase()) {
      toast.error(t('source.reservedGroupName', { name: UNGROUPED_SOURCE_GROUP, defaultValue: `不能使用系统保留字「${UNGROUPED_SOURCE_GROUP}」作为分组名称` }))
      return
    }
    const group = resolveTargetGroup(target, newGroupName)
    if (!group) {
      toast.info(t('source.chooseTargetGroupPrompt', '请选择目标分组，或填写新分组名称'))
      return
    }
    void applyGroup(group)
  }

  const handleRename = async (group: SourceGroupSummary) => {
    const next = editingName.trim()
    if (!next || next === group.name) {
      setEditingGroup(null)
      return
    }
    if (next.toLowerCase() === UNGROUPED_SOURCE_GROUP.toLowerCase()) {
      toast.error(t('source.reservedGroupName', { name: UNGROUPED_SOURCE_GROUP, defaultValue: `不能使用系统保留字「${UNGROUPED_SOURCE_GROUP}」作为分组名称` }))
      return
    }
    setBusy(true)
    try {
      const resp = await api.renameSourceGroup(group.name, next)
      toast.success(resp.message)
      if (target === group.name) setTarget(next)
      setEditingGroup(null)
      await reload()
      await onChanged()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('source.renameGroupFailed', '重命名分组失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleDelete = async (group: SourceGroupSummary) => {
    if (!window.confirm(groupDeleteConfirmMessage(group, t))) return
    setBusy(true)
    try {
      const resp = await api.clearSourceGroup(group.name)
      toast.success(resp.message)
      if (target === group.name) setTarget('')
      await reload()
      await onChanged()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('source.deleteGroupFailed', '删除分组失败'))
    } finally {
      setBusy(false)
    }
  }

  const ungroupedCount = sources.filter(source => !source.group).length

  return (
    <Modal
      opened
      onClose={onClose}
      size="xl"
      zIndex={340}
      withCloseButton={false}
      padding="lg"
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" wrap="wrap" gap="sm" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
          <Stack gap={2}>
            <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
              {t('source.sectionKicker', '书源分类')}
            </Text>
            <Text fw={700} size="lg">{t('source.groupManage', '分组管理')}</Text>
            <Text size="xs" c="dimmed">{t('source.groupManageDesc', '按分组收纳书源，搜书时即可按分组收窄范围')}</Text>
          </Stack>
          <Group gap="xs" wrap="nowrap">
            <Badge variant="light" color="brand" size="md">
              {localGroups.length} {t('source.statGroups', '分组')}
            </Badge>
            <Badge variant="light" color="gray" size="md">
              {sources.length} {t('source.statSources', '书源')}
            </Badge>
            <Badge variant="light" color={ungroupedCount > 0 ? 'gold' : 'gray'} size="md">
              {ungroupedCount} {t('source.statUngrouped', '未分组')}
            </Badge>
            <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
              <Icon name="close" size={16} />
            </ActionIcon>
          </Group>
        </Group>

        <ScrollArea.Autosize mah="68vh" offsetScrollbars>
          <Stack gap="lg" pr={4}>
            <Stack gap="xs">
              <Group justify="space-between" wrap="wrap" gap="xs">
                <Group gap={6}>
                  <Icon name="folder" size={16} />
                  <Text fw={600} size="sm">{t('source.existingGroups', '已有分组')}</Text>
                </Group>
                <Text size="xs" c="dimmed">{t('source.existingGroupsHint', '重命名或删除分组 —— 组内书源不会被删除')}</Text>
              </Group>

              {localGroups.length === 0 ? (
                <Paper p="lg" withBorder radius="md">
                  <Stack align="center" gap={4}>
                    <Icon name="folder" size={24} />
                    <Text size="sm" fw={600}>{t('source.noGroupsYet', '还没有分组')}</Text>
                    <Text size="xs" c="dimmed">{t('source.noGroupsHint', '在下方勾选书源并填写新分组名即可创建')}</Text>
                  </Stack>
                </Paper>
              ) : (
                <Stack gap={6}>
                  {localGroups.map(group => (
                    <Paper key={group.name} p="xs" withBorder radius="md">
                    {editingGroup === group.name ? (
                      <Group gap="xs" wrap="nowrap">
                        <Avatar size="sm" radius="xl" color="brand">{groupInitial(group.name)}</Avatar>
                        <TextInput
                          size="xs"
                          style={{ flex: 1 }}
                          value={editingName}
                          onChange={event => setEditingName(event.target.value)}
                          autoFocus
                          maxLength={20}
                          onKeyDown={event => {
                            if (event.key === 'Enter') void handleRename(group)
                            if (event.key === 'Escape') setEditingGroup(null)
                          }}
                        />
                        <Tooltip label={t('common.save', '保存')}>
                          <ActionIcon color="brand" variant="light" onClick={() => void handleRename(group)} disabled={busy} aria-label={t('common.save', '保存')}>
                            <Icon name="check" size={14} />
                          </ActionIcon>
                        </Tooltip>
                        <Tooltip label={t('common.cancel', '取消')}>
                          <ActionIcon color="gray" variant="subtle" onClick={() => setEditingGroup(null)} aria-label={t('common.cancel', '取消')}>
                            <Icon name="close" size={14} />
                          </ActionIcon>
                        </Tooltip>
                      </Group>
                    ) : (
                      <Group justify="space-between" wrap="nowrap">
                        <Group gap="xs" wrap="nowrap" style={{ minWidth: 0 }}>
                          <Avatar size="sm" radius="xl" color="brand">{groupInitial(group.name)}</Avatar>
                          <Text size="sm" fw={600} truncate>{group.name}</Text>
                          <Badge size="xs" variant="light" color="gray">
                            {t('source.sourcesCount', { count: group.sourceCount, defaultValue: `${group.sourceCount} 个` })}
                          </Badge>
                          <Badge size="xs" variant="light" color="teal">
                            {t('source.enabledCountBadge', { count: group.enabledCount, defaultValue: `启用 ${group.enabledCount}` })}
                          </Badge>
                        </Group>
                        <Group gap={4} wrap="nowrap">
                          <Tooltip label={t('source.rename', '重命名')}>
                            <ActionIcon
                              variant="subtle"
                              color="gray"
                              disabled={busy}
                              onClick={() => {
                                setEditingGroup(group.name)
                                setEditingName(group.name)
                              }}
                              aria-label={t('source.rename', '重命名')}
                            >
                              <Icon name="edit" size={14} />
                            </ActionIcon>
                          </Tooltip>
                          <Tooltip label={t('source.deleteGroupTitle', '删除分组（书源不会被删除）')}>
                            <ActionIcon
                              variant="subtle"
                              color="red"
                              disabled={busy}
                              onClick={() => void handleDelete(group)}
                              aria-label={t('common.delete', '删除')}
                            >
                              <Icon name="trash" size={14} />
                            </ActionIcon>
                          </Tooltip>
                        </Group>
                      </Group>
                    )}
                    </Paper>
                  ))}
                </Stack>
              )}
            </Stack>

            <Divider />

            <Stack gap="sm">
              <Group justify="space-between" wrap="wrap" gap="xs">
                <Group gap={6}>
                  <Icon name="list" size={16} />
                  <Text fw={600} size="sm">{t('source.addSourcesToGroup', '把书源加入分组')}</Text>
                </Group>
                <Text size="xs" c="dimmed">{t('source.addSourcesToGroupHint', '先勾选书源，再选目标分组')}</Text>
              </Group>

              <Group align="flex-end" wrap="wrap" gap="xs">
                <Select
                  size="xs"
                  label={t('source.targetGroup', '目标分组')}
                  comboboxProps={{ zIndex: 380 }}
                  placeholder={t('source.selectPlaceholder', '请选择…')}
                  value={target || null}
                  onChange={value => setTarget(value ?? '')}
                  data={[
                    ...localGroups.map(group => ({ value: group.name, label: group.name })),
                    { value: NEW_GROUP_OPTION, label: t('source.newGroupOption', '+ 新建分组…') },
                  ]}
                  style={{ minWidth: 180, flex: 1 }}
                />
                {target === NEW_GROUP_OPTION && (
                  <TextInput
                    size="xs"
                    label={t('source.newGroupPlaceholder', '新分组名称')}
                    value={newGroupName}
                    placeholder={t('source.newGroupPlaceholder', '新分组名称')}
                    maxLength={20}
                    onChange={event => setNewGroupName(event.target.value)}
                    style={{ minWidth: 160, flex: 1 }}
                  />
                )}
                <Group gap="xs">
                  <Button size="xs" disabled={busy} onClick={handleAddToGroup}>
                    {t('source.addToGroup', '加入分组')}
                  </Button>
                  <Button size="xs" variant="default" disabled={busy} onClick={() => void applyGroup(null)}>
                    {t('source.removeFromGroup', '移出分组')}
                  </Button>
                </Group>
              </Group>

              <Group justify="space-between" wrap="wrap" gap="xs">
                <TextInput
                  size="xs"
                  leftSection={<Icon name="search" size={14} />}
                  placeholder={t('source.filterSourcesPlaceholder', '筛选书源（名称 / 地址 / 分组）')}
                  value={query}
                  onChange={event => setQuery(event.target.value)}
                  style={{ flex: 1, minWidth: 200 }}
                />
                <Group gap={6} wrap="wrap">
                  <Text size="xs" c="dimmed">
                    {t('source.selectedCount', '已选 {{count}} / {{total}}', { count: selectedIds.size, total: visibleSources.length })}
                  </Text>
                  <Button size="compact-xs" variant="subtle" onClick={selectAllVisible}>{t('source.selectAll', '全选')}</Button>
                  <Button size="compact-xs" variant="subtle" onClick={clearSelection}>{t('source.deselectAll', '全不选')}</Button>
                  <Button size="compact-xs" variant="subtle" onClick={invertSelection}>{t('source.invertSelection', '反选')}</Button>
                </Group>
              </Group>

              <Box aria-label={t('source.sourceList', '书源列表')}>
                <Stack gap={4}>
                  {visibleSources.map(source => {
                    const checked = selectedIds.has(source.id)
                    return (
                      <Paper
                        key={source.id}
                        p="xs"
                        withBorder
                        radius="sm"
                        style={{
                          cursor: 'pointer',
                          borderColor: checked ? 'var(--accent)' : undefined,
                          background: checked ? 'var(--accent-soft)' : undefined,
                        }}
                        onClick={() => toggleSelect(source.id)}
                      >
                        <Group justify="space-between" wrap="nowrap" gap="xs">
                          <Group gap="xs" wrap="nowrap" style={{ minWidth: 0, flex: 1 }}>
                            <Checkbox
                              checked={checked}
                              onChange={() => toggleSelect(source.id)}
                              onClick={e => e.stopPropagation()}
                            />
                            <Text size="sm" fw={500} truncate>{source.name}</Text>
                            {!source.enabled && (
                              <Badge size="xs" variant="light" color="gray">{t('source.disabledBadge', '已停用')}</Badge>
                            )}
                          </Group>
                          <Badge size="xs" variant="light" color={source.group ? 'brand' : 'gold'}>
                            {source.group || t('source.statUngrouped', '未分组')}
                          </Badge>
                        </Group>
                      </Paper>
                    )
                  })}
                  {visibleSources.length === 0 && (
                    <Text size="sm" c="dimmed" ta="center" py="md">
                      {t('source.noMatchingSources', '没有匹配的书源')}
                    </Text>
                  )}
                </Stack>
              </Box>
            </Stack>
          </Stack>
        </ScrollArea.Autosize>

        <Group justify="space-between" align="center" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
          <Text size="xs" c="dimmed">
            {selectedIds.size > 0
              ? t('source.selectedSourcesCount', { count: selectedIds.size, defaultValue: `已选中 ${selectedIds.size} 个书源` })
              : t('source.selectSourcesPrompt', '勾选书源后可批量归类')}
          </Text>
          <Button onClick={onClose}>{t('common.done', '完成')}</Button>
        </Group>
      </Stack>
    </Modal>
  )
}
