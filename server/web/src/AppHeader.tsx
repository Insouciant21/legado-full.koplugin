import React, { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useTranslation } from 'react-i18next'
import { Icon } from './icons'
import { Logo } from './Logo'
import type { ReaderSettings } from './readerSettings'
import { api } from './api'

export type AppPage = 'sources' | 'library' | 'shelf' | 'devices' | 'reader'

export interface AppHeaderProps {
  page: AppPage
  settings: ReaderSettings
  searching?: boolean
  taskCount?: number
  onTaskCountChange?: (count: number) => void
  onSettingsChange: (next: ReaderSettings) => void
  onNavigate: (page: AppPage) => void
  onOpenConfigImport: () => void
  onLogout: () => void
}

export const APP_THEMES: ReadonlyArray<{ id: ReaderSettings['theme']; name: string; key: string }> = [
  { id: 'light', name: '晓白', key: 'header.themeLight' },
  { id: 'paper', name: '护眼', key: 'header.themePaper' },
  { id: 'dark', name: '夜读', key: 'header.themeDark' },
]

const APP_NAVIGATION = [
  { id: 'library', icon: 'compass', labelKey: 'header.findBooks', fallback: '找书' },
  { id: 'shelf', icon: 'library', labelKey: 'header.myReading', fallback: '阅读' },
  { id: 'sources', icon: 'source', labelKey: 'header.sourceCenter', fallback: '书源' },
  { id: 'devices', icon: 'device', labelKey: 'header.devices', fallback: '设备与任务' },
] as const

export function AppHeader({
  page,
  settings,
  searching,
  taskCount = 0,
  onTaskCountChange,
  onSettingsChange,
  onNavigate,
  onOpenConfigImport,
  onLogout,
}: AppHeaderProps) {
  const { t } = useTranslation()
  const [menuOpen, setMenuOpen] = useState(false)

  const menuButtonRef = useRef<HTMLButtonElement>(null)
  const menuContainerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!menuOpen) return

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setMenuOpen(false)
      }
    }

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target as Node
      if (
        menuContainerRef.current &&
        !menuContainerRef.current.contains(target) &&
        !menuButtonRef.current?.contains(target)
      ) {
        setMenuOpen(false)
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    window.addEventListener('pointerdown', handlePointerDown)

    return () => {
      window.removeEventListener('keydown', handleKeyDown)
      window.removeEventListener('pointerdown', handlePointerDown)
    }
  }, [menuOpen])

  useEffect(() => {
    if (page !== 'devices') return
    const controller = new AbortController()
    let timer = 0
    const poll = async () => {
      try {
        const [deliveries, publish] = await Promise.all([
          api.kindlePushDeliveries(),
          api.kindleAutoPublishStatus(),
        ])
        if (controller.signal.aborted) return
        const queueCount = deliveries.deliveries.filter(item => item.state === 'queued' || item.state === 'partial').length
        const publishActive = ['caching', 'waiting', 'publishing', 'blocked', 'failed'].includes(publish.state) ? 1 : 0
        onTaskCountChange?.(queueCount + publishActive)
      } catch {
        if (!controller.signal.aborted) onTaskCountChange?.(0)
      }
      if (!controller.signal.aborted) timer = window.setTimeout(() => void poll(), 5_000)
    }
    void poll()
    return () => {
      controller.abort()
      window.clearTimeout(timer)
    }
  }, [onTaskCountChange, page])

  const handleLogout = () => {
    if (window.confirm(t('header.logoutConfirm'))) {
      setMenuOpen(false)
      onLogout()
    }
  }

  const handleThemeChange = (theme: ReaderSettings['theme']) => {
    onSettingsChange({ ...settings, theme })
  }

  const canUseDOM = typeof document !== 'undefined'

  const menuDropdownContent = menuOpen ? (
    <div className={`header-menu-portal-wrapper theme-${settings.theme}`}>
      <div
        className="header-menu-backdrop"
        onClick={() => setMenuOpen(false)}
        aria-hidden="true"
      />
      <div className={`header-menu-dropdown theme-${settings.theme}`} ref={menuContainerRef} role="menu" aria-label={t('header.functionMenu')}>
        <div className="menu-header">
          <div className="menu-status-badge">
            <span className="menu-status-dot" />
            <span className="menu-header-title">{t('header.serviceLoggedIn')}</span>
          </div>
        </div>

        <div className="menu-section">
          <div className="menu-section-label">{t('header.themeSection')}</div>
          <div className="menu-theme-grid" role="radiogroup" aria-label={t('header.themeSection')}>
            {APP_THEMES.map(themeItem => {
              const isSelected = settings.theme === themeItem.id
              return (
                <button
                  key={themeItem.id}
                  type="button"
                  className={`menu-theme-btn theme-option-${themeItem.id} ${isSelected ? 'selected' : ''}`}
                  role="radio"
                  aria-checked={isSelected}
                  onClick={() => handleThemeChange(themeItem.id)}
                >
                  <span className={`theme-swatch theme-swatch-${themeItem.id}`} />
                  <span className="theme-name">{t(themeItem.key, themeItem.name)}</span>
                  {isSelected && <Icon name="check" className="theme-check-icon" />}
                </button>
              )
            })}
          </div>
        </div>

        <div className="menu-divider" />

        <div className="menu-section">
          <button
            type="button"
            className="menu-item-btn"
            role="menuitem"
            onClick={() => {
              setMenuOpen(false)
              onOpenConfigImport()
            }}
          >
            <Icon name="importFile" />
            <span>{t('header.webdav', '备份导入')}</span>
          </button>
        </div>

        <div className="menu-divider" />

        <div className="menu-section">
          <button
            type="button"
            className="menu-logout-btn"
            role="menuitem"
            onClick={handleLogout}
          >
            <Icon name="logOut" />
            <span>{t('header.logout')}</span>
          </button>
        </div>
      </div>
    </div>
  ) : null

  return (
    <header className="app-page-header">
      <div className="app-sidebar-brand">
        <button
          type="button"
          className="app-brand"
          onClick={() => onNavigate('library')}
          aria-label={t('login.brand')}
        >
          <span className="app-brand-mark"><Logo size={28} /></span>
          <span className="app-brand-copy">
            <strong>{t('login.brand')}</strong>
            <small>你的私人阅读服务器</small>
          </span>
        </button>
      </div>

      <div className="app-nav-section">
        <span className="app-nav-label">工作台</span>
        <nav aria-label={t('header.mainNav')}>
          {APP_NAVIGATION.map(item => (
            <button
              key={item.id}
              type="button"
              className={page === item.id ? 'active' : ''}
              data-nav={item.id}
              aria-current={page === item.id ? 'page' : undefined}
              onClick={() => onNavigate(item.id)}
            >
              <span className="app-nav-icon" aria-hidden="true">
                <Icon name={item.icon} />
              </span>
              <span className="app-nav-copy">
                <strong>{t(item.labelKey, item.fallback)}</strong>
              </span>
              {item.id === 'library' && searching && (
                <span
                  className="nav-search-indicator"
                  title={t('header.searchingInBackground')}
                  aria-label={t('header.searchingInBackground')}
                />
              )}
              {(item.id === 'shelf' || item.id === 'devices') && taskCount > 0 && (
                <span
                  className="nav-task-count"
                  title={`${taskCount} 项后台任务`}
                  aria-label={`${taskCount} 项后台任务`}
                >
                  {taskCount > 99 ? '99+' : taskCount}
                </span>
              )}
            </button>
          ))}
        </nav>
      </div>

      <div className="header-connection-card">
        <span className="header-connection-icon"><Icon name="activity" /></span>
        <span>
          <strong>{t('header.serviceLoggedIn', '服务已连接')}</strong>
          <small>找书、阅读、书源与任务同步</small>
        </span>
        <i aria-hidden="true" />
      </div>

      <div className="header-sidebar-tools" aria-label={t('header.functionMenu', '功能菜单')}>
        <button type="button" onClick={onOpenConfigImport}>
          <Icon name="importFile" />
          <span>{t('header.webdav', '备份导入')}</span>
        </button>
      </div>

      <div className="header-actions">
        <button
          type="button"
          ref={menuButtonRef}
          className={`header-menu-btn ${menuOpen ? 'active' : ''}`}
          aria-label={menuOpen ? t('header.closeMenu') : t('header.openMenu')}
          aria-expanded={menuOpen}
          aria-haspopup="true"
          onClick={() => setMenuOpen(prev => !prev)}
        >
          <Icon name="menu" />
          <span>{menuOpen ? t('header.closeMenu') : t('header.openMenu')}</span>
        </button>

        {menuDropdownContent && (canUseDOM ? createPortal(menuDropdownContent, document.body) : menuDropdownContent)}
      </div>
    </header>
  )
}
