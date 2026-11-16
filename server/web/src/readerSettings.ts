export type ReaderTheme = 'light' | 'paper' | 'dark'

export type ReaderSettings = {
  theme: ReaderTheme
}

const storageKey = 'legado-reader-settings-v2'
export type MediaBookKind = 'comic' | 'audio'

export type MediaReaderState = {
  book: {
    bookKind?: string
    bookUrl?: string
    details?: { sourceId?: string; name?: string }
    chapters?: unknown[]
  }
  index: number
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
}

function isUsableChapter(value: unknown): value is { index: number; title: string; url: string } {
  if (!value || typeof value !== 'object') return false
  const chapter = value as { index?: unknown; title?: unknown; url?: unknown }
  return isNonNegativeInteger(chapter.index)
    && typeof chapter.title === 'string' && chapter.title.trim().length > 0
    && typeof chapter.url === 'string' && chapter.url.trim().length > 0
}

export function isMediaReaderState(value: unknown): value is MediaReaderState {
  if (!value || typeof value !== 'object') return false
  const state = value as Partial<MediaReaderState>
  const book = state.book
  if (!book || typeof book !== 'object') return false
  if (book.bookKind !== 'comic' && book.bookKind !== 'audio') return false
  if (!isNonNegativeInteger(state.index)) return false
  if (typeof book.bookUrl !== 'string' || book.bookUrl.trim().length === 0) return false
  const details = book.details
  if (!details || typeof details !== 'object') return false
  if (typeof details.sourceId !== 'string' || details.sourceId.trim().length === 0) return false
  if (typeof details.name !== 'string' || details.name.trim().length === 0) return false
  return Array.isArray(book.chapters)
    && book.chapters.length > 0
    && book.chapters.every(isUsableChapter)
}

export function loadMediaReaderState<T extends MediaReaderState>(
  storage: Pick<Storage, 'getItem' | 'removeItem'>,
  key: string,
): T | null {
  try {
    const raw = storage.getItem(key)
    if (!raw) return null
    try {
      const parsed = JSON.parse(raw) as unknown
      if (isMediaReaderState(parsed)) return parsed as T
    } catch {
      // Fall through and remove malformed state.
    }
    try {
      storage.removeItem(key)
    } catch {
      // Cleanup must never turn stale reader state into a startup error.
    }
    return null
  } catch {
    // Privacy modes and storage permission failures must recover to the shelf.
    return null
  }
}

export const defaultReaderSettings: ReaderSettings = {
  theme: 'light',
}

export function loadReaderSettings(): ReaderSettings {
  try {
    const raw = window.localStorage.getItem(storageKey) || window.localStorage.getItem('legado-reader-settings-v1')
    const saved = JSON.parse(raw ?? '{}') as Partial<ReaderSettings>
    return {
      theme: saved.theme === 'paper' || saved.theme === 'dark' ? saved.theme : defaultReaderSettings.theme,
    }
  } catch {
    return defaultReaderSettings
  }
}

export function saveReaderSettings(settings: ReaderSettings): void {
  window.localStorage.setItem(storageKey, JSON.stringify(settings))
}



