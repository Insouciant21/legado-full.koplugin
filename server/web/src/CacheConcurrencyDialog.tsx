import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { useTranslation } from 'react-i18next'
import { Icon } from './icons'
import { ButtonSpinner } from './ButtonSpinner'

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

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) onCancel()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [busy, onCancel])

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

  return createPortal(
    <div
      className="modal-backdrop top-layer-modal-backdrop"
      onClick={event => {
        event.stopPropagation()
        if (!busy) onCancel()
      }}
    >
      <div
        className="cache-concurrency-dialog"
        onClick={event => event.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={t('shelf.cacheConcurrencyDialogLabel', '设置《{{name}}》的缓存并发', { name: bookName })}
      >
        <header className="cache-concurrency-header">
          <div className="cache-concurrency-heading">
            <span className="cache-concurrency-icon"><Icon name="sliders" /></span>
            <div>
              <span className="section-kicker">{t('shelf.cacheConcurrencyKicker', '离线缓存设置')}</span>
              <h2>{t('shelf.cacheConcurrencyTitle', '选择章节并发')}</h2>
            </div>
          </div>
          <button
            type="button"
            className="subtle-button close-btn"
            disabled={busy}
            onClick={onCancel}
            aria-label={t('common.close', '关闭')}
          >
            <Icon name="close" />
          </button>
        </header>

        <div className="cache-concurrency-body">
          <p>
            {t('shelf.cacheConcurrencyDescription', '《{{name}}》本次最多同时下载 {{count}} 章。并发越高，下载越快，也越容易触发书源限流。', {
              name: bookName,
              count: chapterConcurrency,
            })}
          </p>

          <div className="cache-concurrency-value" aria-live="polite">
            <strong>{chapterConcurrency}</strong>
            <span>{t('shelf.cacheConcurrencyUnit', '章并发')}</span>
          </div>

          <input
            className="cache-concurrency-range"
            type="range"
            min={MIN_BOOK_CACHE_CONCURRENCY}
            max={MAX_BOOK_CACHE_CONCURRENCY}
            step="1"
            value={chapterConcurrency}
            disabled={busy}
            aria-label={t('shelf.cacheConcurrencySliderLabel', '章节并发数')}
            onChange={event => setChapterConcurrency(Number(event.target.value))}
          />

          <div className="cache-concurrency-presets" role="group" aria-label={t('shelf.cacheConcurrencyPresetsLabel', '常用并发选项')}>
            {PRESETS.map(value => (
              <button
                key={value}
                type="button"
                className={chapterConcurrency === value ? 'active' : ''}
                disabled={busy}
                onClick={() => setChapterConcurrency(value)}
              >
                {value}
              </button>
            ))}
          </div>

          <div className="cache-concurrency-hint">
            <Icon name="activity" />
            <span>{speedHint}</span>
          </div>
          <small className="cache-concurrency-global-hint">
            {t('shelf.cacheConcurrencyGlobalHint', '服务端全局同时最多抓取 9 章；多本书同时缓存时会共享这 9 个槽位。')}
          </small>
        </div>

        <footer className="cache-concurrency-footer">
          <button type="button" className="subtle-button" disabled={busy} onClick={onCancel}>
            {t('common.cancel', '取消')}
          </button>
          <button type="button" className="primary-button" disabled={busy} onClick={confirm}>
            {busy && <ButtonSpinner size={14} />}
            {busy
              ? t('shelf.startingCache', '启动缓存...')
              : t('shelf.cacheConcurrencyStart', '按 {{count}} 并发开始', { count: chapterConcurrency })}
          </button>
        </footer>
      </div>
    </div>,
    document.body,
  )
}
