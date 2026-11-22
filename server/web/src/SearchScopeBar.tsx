import { Badge, Button, Group, Select, Text, Tooltip } from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { SourceGroupSummary, SourceSummary, UNGROUPED_SOURCE_GROUP } from './api'
import { Icon } from './icons'

export function removeGroupSourceOverrides(selectedSourceIds: string[], groupMemberIds: string[]) {
  const members = new Set(groupMemberIds)
  return selectedSourceIds.filter(id => !members.has(id))
}

export interface SearchScopeBarProps {
  groups: SourceGroupSummary[]
  sources?: SourceSummary[]
  selectedGroups?: string[]
  selectedSourceIds?: string[]
  selectedGroup?: string
  selectedSourceId?: string
  onSelectAll: () => void
  onToggleGroup?: (group: string) => void
  onOpenPicker?: () => void
  onSelectGroup?: (group: string) => void
  onSelectSource?: (sourceId: string) => void
}

export function SearchScopeBar({
  groups,
  sources,
  selectedGroups,
  selectedSourceIds,
  selectedGroup = '',
  selectedSourceId = '',
  onSelectAll,
  onToggleGroup,
  onOpenPicker,
  onSelectGroup,
  onSelectSource,
}: SearchScopeBarProps) {
  const { t } = useTranslation()
  const effectiveGroups = selectedGroups ?? (selectedGroup ? [selectedGroup] : [])
  const effectiveSourceIds = selectedSourceIds ?? (selectedSourceId ? [selectedSourceId] : [])
  const groupSet = new Set(effectiveGroups)
  const allSelected = effectiveGroups.length === 0 && effectiveSourceIds.length === 0
  const hasCustomScope = effectiveGroups.length > 0 || effectiveSourceIds.length > 0
  const pickerLabel = effectiveGroups.length > 0 && effectiveSourceIds.length > 0
    ? t('search.scopeMixed', '{{groups}} 个分组 + {{sources}} 个书源', { groups: effectiveGroups.length, sources: effectiveSourceIds.length })
    : effectiveGroups.length > 0
      ? t('search.scopeSelectedGroupNames', '已选分组：{{groups}}', {
          groups: effectiveGroups.map(group => group === UNGROUPED_SOURCE_GROUP ? t('search.scopeUngrouped', '未分组') : group).join('、'),
        })
      : effectiveSourceIds.length > 0
        ? t('search.scopeSelectedSources', '已选 {{count}} 个书源', { count: effectiveSourceIds.length })
        : t('search.scopePickSources', '选择书源')

  const toggleGroup = onToggleGroup ?? onSelectGroup ?? (() => undefined)

  return (
    <Group gap={6} wrap="wrap" align="center" role="tablist" aria-label={t('search.scopeLabel')}>
      <Text size="xs" fw={600} c="dimmed" mr={2}>{t('search.scopeLabel')}</Text>
      {onOpenPicker && (
        <Button
          size="compact-xs"
          radius="xl"
          variant={hasCustomScope ? 'filled' : 'light'}
          color="brand"
          leftSection={<Icon name="sliders" size={12} />}
          onClick={onOpenPicker}
          aria-label={t('search.scopePickerAria', '打开搜索范围选择器')}
          title={pickerLabel}
        >
          {pickerLabel}
        </Button>
      )}
      <Button
        size="compact-xs"
        radius="xl"
        role="tab"
        aria-selected={allSelected}
        variant={allSelected ? 'filled' : 'subtle'}
        color={allSelected ? 'dark' : 'gray'}
        onClick={onSelectAll}
        title={t('search.scopeAllTitle')}
      >
        {t('search.scopeAll')}
      </Button>
      {groups.map(group => (
        <Tooltip
          key={group.name}
          label={t('search.scopeGroupTitle', { total: group.sourceCount, enabled: group.enabledCount, defaultValue: `分组内共 ${group.sourceCount} 个书源，其中 ${group.enabledCount} 个已启用（只有已启用的会参与搜索）` })}
        >
          <Button
            size="compact-xs"
            radius="xl"
            role="tab"
            aria-selected={groupSet.has(group.name)}
            variant={groupSet.has(group.name) ? 'filled' : 'default'}
            color={groupSet.has(group.name) ? 'brand' : 'gray'}
            onClick={() => toggleGroup(group.name)}
            rightSection={<Badge size="xs" variant="transparent" px={0} color="inherit">{group.enabledCount}</Badge>}
          >
            {group.name}
          </Button>
        </Tooltip>
      ))}
      <Button
        size="compact-xs"
        radius="xl"
        role="tab"
        aria-selected={groupSet.has(UNGROUPED_SOURCE_GROUP)}
        variant={groupSet.has(UNGROUPED_SOURCE_GROUP) ? 'filled' : 'default'}
        color={groupSet.has(UNGROUPED_SOURCE_GROUP) ? 'brand' : 'gray'}
        onClick={() => toggleGroup(UNGROUPED_SOURCE_GROUP)}
        title={t('search.scopeUngroupedTitle')}
      >
        {t('search.scopeUngrouped')}
      </Button>
      {!onOpenPicker && sources && onSelectSource ? (
        <Select
          size="xs"
          w={180}
          aria-label={t('search.singleSourceAria')}
          value={selectedSourceId}
          onChange={value => onSelectSource(value ?? '')}
          data={[
            { value: '', label: t('search.unlimited') },
            ...sources.map(source => ({ value: source.id, label: source.name })),
          ]}
        />
      ) : null}
    </Group>
  )
}
