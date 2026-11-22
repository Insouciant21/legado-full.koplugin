export type AppPage = 'sources' | 'library' | 'shelf' | 'devices' | 'reader'

const PAGE_PATHS: Record<AppPage, string> = {
  library: '/',
  shelf: '/library/',
  sources: '/sources/',
  devices: '/devices/',
  reader: '/reader/',
}

const LEGACY_HASH_PAGES: Record<string, AppPage> = {
  '#sources': 'sources',
  '#shelf': 'shelf',
  '#devices': 'devices',
  '#reader': 'reader',
}

function normalizePath(pathname: string): string {
  const normalized = pathname.replace(/\/+$/, '') || '/'
  if (normalized === '/library') return '/library/'
  if (normalized === '/sources') return '/sources/'
  if (normalized === '/devices') return '/devices/'
  if (normalized === '/reader') return '/reader/'
  return normalized
}

export function pageFromPath(pathname: string, hash = ''): AppPage {
  const legacyPage = LEGACY_HASH_PAGES[hash]
  if (legacyPage) return legacyPage

  switch (normalizePath(pathname)) {
    case '/library/':
      return 'shelf'
    case '/sources/':
      return 'sources'
    case '/devices/':
      return 'devices'
    case '/reader/':
      return 'reader'
    default:
      return 'library'
  }
}

export function pathForPage(page: AppPage): string {
  return PAGE_PATHS[page]
}

