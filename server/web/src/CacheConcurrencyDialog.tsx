import { useState } from 'react'
import { Alert, Button, Group, Modal, SegmentedControl, Slider, Stack, Text } from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { Icon } from './icons'

export const MIN_BOOK_CACHE_CONCURRENCY = 1
export const MAX_BOOK_CACHE_CONCURRENCY = 9
export const DEFAULT_BOOK_CACHE_CONCURRENCY = MAX_BOOK_CACHE_CONCURRENCY

const CACHE_CONCURRENCY_STORAGE_KEY = 'legado-book-cache-concurrency-v1'
const PRESETS = [1, 3, 6, 9] as const

function normalizeConcurrency(value: number | undefined): number {
  if (!Number.isFinite(value)) return DEFAULT_BOOK_CACHE_CONCURRENCY
  return Math.max(
    MIN_BOOK_CACHE_CONCURRENCY,
    Math.min(MAX_BOOK_CACHE_CONCURRENCY, Math.round(value as number)),
  )
}

export function loadPreferredCacheConcurrency(): number {
  try {
    const raw = window.localStorage.getItem(CACHE_CONCURRENCY_STORAGE_KEY)
    return raw == null ? DEFAULT_BOOK_CACHE_CONCURRENCY : normalizeConcurrency(Number(raw))
  } catch {
    return DEFAULT_BOOK_CACHE_CONCURRENCY
  }
}

export function savePreferredCacheConcurrency(value: number) {
  const normalized = normalizeConcurrency(value)
  try {
    window.localStorage.setItem(CACHE_CONCURRENCY_STORAGE_KEY, String(normalized))
  } catch {
    // Storage can be disabled in private browsing. The current server-side task still keeps its value.
  }
}

export function CacheConcurrencyDialog({
  bookName,
  initialConcurrency,
  busy = false,
  onCancel,
  onConfirm,
}: {
  bookName: string
  initialConcurrency?: number
  busy?: boolean
  onCancel: () => void
  onConfirm: (chapterConcurrency: number) => void
}) {
  const { t } = useTranslation()
  const [chapterConcurrency, setChapterConcurrency] = useState(() =>
    normalizeConcurrency(initialConcurrency ?? loadPreferredCacheConcurrency())
  )

  const speedHint = chapterConcurrency <= 2
    ? t('shelf.cacheConcurrencyStable', '更稳妥，适合容易限流或封禁的书源')
    : chapterConcurrency <= 5
      ? t('shelf.cacheConcurrencyBalanced', '速度与稳定性平衡')
      : t('shelf.cacheConcurrencyFast', '下载更快，但更容易触发书源限流')

  const confirm = () => {
    const normalized = normalizeConcurrency(chapterConcurrency)
    savePreferredCacheConcurrency(normalized)
    onConfirm(normalized)
  }

  return (
    <Modal
      opened
      onClose={() => {
        if (!busy) onCancel()
      }}
      closeOnClickOutside={!busy}
      closeOnEscape={!busy}
      zIndex={320}
      size="md"
      title={
        <Group gap="xs">
          <Icon name="sliders" size={18} />
          <Text fw={700}>{t('shelf.cacheConcurrencyTitle', '选择章节并发')}</Text>
        </Group>
      }
    >
      <Stack gap="md">
        <Text size="sm" c="dimmed">
          {t('shelf.cacheConcurrencyDescription', '《{{name}}》本次最多同时下载 {{count}} 章。并发越高，下载越快，也越容易触发书源限流。', {
            name: bookName,
            count: chapterConcurrency,
          })}
        </Text>

        <Group justify="space-between" align="baseline">
          <Text size="sm" fw={600}>{t('shelf.cacheConcurrencySliderLabel', '章节并发数')}</Text>
          <Text size="xl" fw={700} c="brand">
            {chapterConcurrency} {t('shelf.cacheConcurrencyUnit', '章并发')}
          </Text>
        </Group>

        <Slider
          min={MIN_BOOK_CACHE_CONCURRENCY}
          max={MAX_BOOK_CACHE_CONCURRENCY}
          step={1}
          value={chapterConcurrency}
          disabled={busy}
          onChange={setChapterConcurrency}
          marks={PRESETS.map(v => ({ value: v, label: String(v) }))}
          mb="xs"
        />

        <SegmentedControl
          fullWidth
          disabled={busy}
          value={PRESETS.includes(chapterConcurrency as (typeof PRESETS)[number]) ? String(chapterConcurrency) : ''}
          onChange={value => {
            if (value) setChapterConcurrency(Number(value))
          }}
          data={PRESETS.map(v => ({ value: String(v), label: `${v} 并发` }))}
        />

        <Alert color={chapterConcurrency <= 2 ? 'teal' : chapterConcurrency <= 5 ? 'blue' : 'yellow'} variant="light" icon={<Icon name="activity" size={16} />}>
          <Stack gap={2}>
            <Text size="sm" fw={500}>{speedHint}</Text>
            <Text size="xs" c="dimmed">
              {t('shelf.cacheConcurrencyGlobalHint', '服务端全局同时最多抓取 9 章；多本书同时缓存时会共享这 9 个槽位。')}
            </Text>
          </Stack>
        </Alert>

        <Group justify="flex-end" gap="xs">
          <Button variant="default" disabled={busy} onClick={onCancel}>
            {t('common.cancel', '取消')}
          </Button>
          <Button loading={busy} onClick={confirm}>
            {busy
              ? t('shelf.startingCache', '启动缓存...')
              : t('shelf.cacheConcurrencyStart', '按 {{count}} 并发开始', { count: chapterConcurrency })}
          </Button>
        </Group>
      </Stack>
    </Modal>
  )
}
