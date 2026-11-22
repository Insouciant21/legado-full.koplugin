import type { ReactNode } from 'react'
import { useEffect } from 'react'
import {
  ActionIcon,
  AppShell,
  Badge,
  Box,
  Button,
  Divider,
  Group,
  Menu,
  NavLink,
  ScrollArea,
  SegmentedControl,
  Stack,
  Text,
  ThemeIcon,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { Icon } from './icons'
import { Logo } from './Logo'
import type { ReaderSettings } from './readerSettings'
import { api } from './api'
import type { AppPage } from './appRoutes'

export type { AppPage } from './appRoutes'

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
  children?: ReactNode
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
  children,
}: AppHeaderProps) {
  const { t } = useTranslation()

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
      onLogout()
    }
  }

  const handleThemeChange = (theme: ReaderSettings['theme']) => {
    onSettingsChange({ ...settings, theme })
  }

  const navBadge = (id: (typeof APP_NAVIGATION)[number]['id']) => {
    if (id === 'library' && searching) {
      return (
        <Tooltip label={t('header.searchingInBackground')}>
          <Badge size="xs" variant="dot" color="brand">搜索中</Badge>
        </Tooltip>
      )
    }
    if ((id === 'shelf' || id === 'devices') && taskCount > 0) {
      return (
        <Badge size="xs" variant="filled" color="gold" radius="xl">
          {taskCount > 99 ? '99+' : taskCount}
        </Badge>
      )
    }
    return undefined
  }

  return (
    <AppShell
      navbar={{ width: 236, breakpoint: 'md', collapsed: { mobile: true } }}
      header={{ height: { base: 58, md: 0 } }}
      padding={{ base: 'sm', sm: 'md', md: 'xl' }}
    >
      <AppShell.Header hiddenFrom="md" px="sm">
        <Group h="100%" justify="space-between" wrap="nowrap" gap="xs">
          <Button
            variant="subtle"
            color="gray"
            px={6}
            onClick={() => onNavigate('library')}
            leftSection={<Logo size={24} />}
            aria-label={t('login.brand')}
            style={{ flexShrink: 0 }}
            styles={{ label: { fontWeight: 700, color: 'var(--ink)' } }}
          >
            <Text span visibleFrom="sm" fw={700} size="sm" c="var(--ink)">
              {t('login.brand')}
            </Text>
          </Button>

          <Group gap={4} wrap="nowrap" style={{ overflowX: 'auto', minWidth: 0 }}>
            {APP_NAVIGATION.map(item => {
              const active = page === item.id
              return (
                <Button
                  key={item.id}
                  size="xs"
                  variant={active ? 'light' : 'subtle'}
                  color={active ? 'brand' : 'gray'}
                  px={10}
                  onClick={() => onNavigate(item.id)}
                  leftSection={<Icon name={item.icon} size={14} />}
                  rightSection={(item.id === 'shelf' || item.id === 'devices') && taskCount > 0 ? (
                    <Badge size="xs" variant="filled" color="gold" px={5} radius="xl">
                      {taskCount > 99 ? '99+' : taskCount}
                    </Badge>
                  ) : undefined}
                  style={{ flexShrink: 0 }}
                >
                  {t(item.labelKey, item.fallback)}
                </Button>
              )
            })}
          </Group>

          <Menu position="bottom-end" withinPortal shadow="md" width={240}>
            <Menu.Target>
              <ActionIcon
                variant="subtle"
                color="gray"
                size="lg"
                aria-label={t('header.openMenu')}
              >
                <Icon name="menu" size={18} />
              </ActionIcon>
            </Menu.Target>
            <Menu.Dropdown>
              <Menu.Label>{t('header.themeSection')}</Menu.Label>
              <Box px="xs" pb="xs">
                <SegmentedControl
                  fullWidth
                  size="xs"
                  value={settings.theme}
                  onChange={value => handleThemeChange(value as ReaderSettings['theme'])}
                  data={APP_THEMES.map(item => ({
                    value: item.id,
                    label: t(item.key, item.name),
                  }))}
                />
              </Box>
              <Menu.Divider />
              <Menu.Item
                leftSection={<Icon name="importFile" size={15} />}
                onClick={onOpenConfigImport}
              >
                {t('header.webdav', '备份导入')}
              </Menu.Item>
              <Menu.Item
                color="red"
                leftSection={<Icon name="logOut" size={15} />}
                onClick={handleLogout}
              >
                {t('header.logout')}
              </Menu.Item>
            </Menu.Dropdown>
          </Menu>
        </Group>
      </AppShell.Header>

      <AppShell.Navbar p="md">
        <AppShell.Section>
          <Group
            gap="sm"
            px={6}
            py={4}
            style={{ cursor: 'pointer' }}
            onClick={() => onNavigate('library')}
          >
            <Logo size={28} />
            <Stack gap={0}>
              <Text fw={700} size="md" lh={1.2}>{t('login.brand')}</Text>
              <Text size="xs" c="dimmed">私人阅读工作台</Text>
            </Stack>
          </Group>
        </AppShell.Section>

        <AppShell.Section grow component={ScrollArea} my="lg">
          <Stack gap={4} component="nav" aria-label={t('header.mainNav')}>
            <Text size="xs" fw={700} c="dimmed" px="sm" mb={4} tt="uppercase" lts={0.8}>
              工作台
            </Text>
            {APP_NAVIGATION.map(item => (
              <NavLink
                key={item.id}
                active={page === item.id}
                label={t(item.labelKey, item.fallback)}
                leftSection={<Icon name={item.icon} size={17} />}
                rightSection={navBadge(item.id)}
                onClick={() => onNavigate(item.id)}
                variant="light"
                color="brand"
                style={{ borderRadius: 8, fontWeight: page === item.id ? 600 : 500 }}
              />
            ))}
          </Stack>
        </AppShell.Section>

        <AppShell.Section>
          <Stack gap="sm">
            <Divider />
            <Stack gap={6}>
              <Text size="xs" fw={600} c="dimmed" px={4}>
                {t('header.themeSection', '界面主题')}
              </Text>
              <SegmentedControl
                fullWidth
                size="xs"
                value={settings.theme}
                onChange={value => handleThemeChange(value as ReaderSettings['theme'])}
                data={APP_THEMES.map(item => ({
                  value: item.id,
                  label: t(item.key, item.name),
                }))}
              />
            </Stack>

            <Stack gap={4}>
              <NavLink
                label={t('header.webdav', '备份导入')}
                leftSection={<Icon name="importFile" size={16} />}
                onClick={onOpenConfigImport}
                style={{ borderRadius: 8 }}
              />
              <NavLink
                label={t('header.logout', '退出登录')}
                leftSection={<Icon name="logOut" size={16} />}
                onClick={handleLogout}
                style={{ borderRadius: 8, color: 'var(--danger)' }}
              />
            </Stack>

            <Group gap="xs" px={8} py={6} style={{ borderRadius: 8, background: 'var(--surface)' }}>
              <ThemeIcon size={22} radius="xl" variant="light" color="brand">
                <Icon name="wifi" size={12} />
              </ThemeIcon>
              <Stack gap={0} style={{ minWidth: 0 }}>
                <Text size="xs" fw={600} truncate>{t('header.serviceLoggedIn', '服务已连接')}</Text>
              </Stack>
            </Group>
          </Stack>
        </AppShell.Section>
      </AppShell.Navbar>

      <AppShell.Main>
        <Box maw={1320} mx="auto" w="100%">
          {children}
        </Box>
      </AppShell.Main>
    </AppShell>
  )
}
