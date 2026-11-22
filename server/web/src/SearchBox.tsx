import React, { useRef } from 'react'
import { ActionIcon, Button, Group, Loader, Paper, TextInput } from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { Icon } from './icons'

export interface SearchBoxProps {
  keyword: string
  loading: boolean
  onChange: (keyword: string) => void
  onSubmit: () => void
  onStop: () => void
}

export function clearSearchInput(
  input: { current: Pick<HTMLInputElement, 'focus'> | null },
  onChange: (keyword: string) => void,
): void {
  onChange('')
  input.current?.focus()
}

export function handleSearchKeyDown(
  event: Pick<React.KeyboardEvent<HTMLInputElement>, 'key' | 'preventDefault'>,
  onClear: () => void,
): void {
  if (event.key !== 'Escape') return
  event.preventDefault()
  onClear()
}

export function SearchBox({ keyword, loading, onChange, onSubmit, onStop }: SearchBoxProps) {
  const { t } = useTranslation()
  const inputRef = useRef<HTMLInputElement>(null)
  const hasContent = keyword.length > 0
  const canSubmit = keyword.trim().length > 0
  const clear = () => clearSearchInput(inputRef, onChange)

  return (
    <Paper
      component="form"
      role="search"
      p={6}
      radius="md"
      shadow="xs"
      onSubmit={event => {
        event.preventDefault()
        onSubmit()
      }}
    >
      <Group gap="xs" wrap="nowrap">
        <TextInput
          ref={inputRef}
          flex={1}
          size="md"
          variant="unstyled"
          px="xs"
          value={keyword}
          onChange={event => onChange(event.target.value)}
          onKeyDown={event => handleSearchKeyDown(event, clear)}
          placeholder={t('library.searchPlaceholder', '输入书名或作者')}
          aria-label={t('library.searchPlaceholder', '输入书名或作者')}
          enterKeyHint="search"
          autoComplete="off"
          spellCheck={false}
          leftSection={<Icon name="search" size={18} />}
          rightSection={
            <Group gap={4} wrap="nowrap">
              {loading && <Loader size={15} aria-label={t('library.searching', '正在搜索')} />}
              {hasContent && (
                <ActionIcon
                  variant="subtle"
                  color="gray"
                  size="sm"
                  onClick={clear}
                  title={t('library.clearSearch', '清空')}
                  aria-label={t('library.clearSearch', '清空')}
                >
                  <Icon name="close" size={14} />
                </ActionIcon>
              )}
            </Group>
          }
          rightSectionWidth={loading && hasContent ? 58 : 34}
        />
        {loading ? (
          <Button type="button" color="red" variant="light" onClick={onStop} leftSection={<Icon name="stop" size={14} />}>
            {t('library.stopSearch', '停止搜索')}
          </Button>
        ) : (
          <Button type="submit" disabled={!canSubmit} leftSection={<Icon name="search" size={15} />}>
            {t('library.startSearch', '搜索')}
          </Button>
        )}
      </Group>
    </Paper>
  )
}
