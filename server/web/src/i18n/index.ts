import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import zhCN from './locales/zh-CN.json'
import { DEFAULT_LOCALE, type SupportedLocale } from './types'

export * from './types'

const coreTranslations = {
  common: zhCN.common,
  header: {
    closeMenu: zhCN.header.closeMenu,
    functionMenu: zhCN.header.functionMenu,
    library: zhCN.header.library,
    logout: zhCN.header.logout,
    logoutConfirm: zhCN.header.logoutConfirm,
    mainNav: zhCN.header.mainNav,
    openMenu: zhCN.header.openMenu,
    searchingInBackground: zhCN.header.searchingInBackground,
    serviceLoggedIn: zhCN.header.serviceLoggedIn,
    shelf: zhCN.header.shelf,
    sources: zhCN.header.sources,
    themeDark: zhCN.header.themeDark,
    themeLight: zhCN.header.themeLight,
    themePaper: zhCN.header.themePaper,
    themeSection: zhCN.header.themeSection,
  },
  login: zhCN.login,
  library: zhCN.library,
  shelf: zhCN.shelf,
  reader: {
    cacheCustomUnit: zhCN.reader.cacheCustomUnit,
    chapterIndex: zhCN.reader.chapterIndex,
    incomplete: zhCN.reader.incomplete,
    previewToc: zhCN.reader.previewToc,
    purchased: zhCN.reader.purchased,
    slowSourceOfflineFallback: zhCN.reader.slowSourceOfflineFallback,
    switchSourceNearestPosition: zhCN.reader.switchSourceNearestPosition,
    totalChapters: zhCN.reader.totalChapters,
    vip: zhCN.reader.vip,
  },
  search: zhCN.search,
  source: zhCN.source,
  errorBoundary: zhCN.errorBoundary,
  toast: { requestFailed: zhCN.toast.requestFailed },
  verification: zhCN.verification,
}

export const resources = {
  'zh-CN': { translation: coreTranslations },
} as const

export function getInitialLocale(): SupportedLocale {
  return DEFAULT_LOCALE
}

const initialLocale = getInitialLocale()

// Synchronously update html lang attribute if document is available
if (typeof document !== 'undefined' && document.documentElement) {
  document.documentElement.lang = initialLocale
}

i18n
  .use(initReactI18next)
  .init({
    resources,
    lng: initialLocale,
    fallbackLng: DEFAULT_LOCALE,
    supportedLngs: ['zh-CN'],
    interpolation: {
      escapeValue: false,
    },
    react: {
      useSuspense: false,
    },
  })

export async function changeAppLanguage(locale: SupportedLocale): Promise<SupportedLocale> {
  await i18n.changeLanguage(locale)
  if (typeof document !== 'undefined' && document.documentElement) document.documentElement.lang = locale
  return locale
}

export function getCurrentLocale(): SupportedLocale {
  return DEFAULT_LOCALE
}

export { i18n }
export default i18n
