export type SupportedLocale = 'zh-CN'

export const DEFAULT_LOCALE: SupportedLocale = 'zh-CN'

export function normalizeLocale(_raw?: string | null): SupportedLocale {
  return DEFAULT_LOCALE
}
