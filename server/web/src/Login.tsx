import { FormEvent, useState } from 'react'
import {
  Alert,
  Box,
  Button,
  Container,
  Group,
  Paper,
  PasswordInput,
  SimpleGrid,
  Stack,
  Text,
  ThemeIcon,
  Title,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, setCsrfToken } from './api'
import { Logo } from './Logo'
import { Icon } from './icons'

export interface LoginProps {
  onLogin: () => void
}

export function Login({ onLogin }: LoginProps) {
  const { t } = useTranslation()
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      const result = await api.login(password)
      setCsrfToken(result.csrfToken)
      onLogin()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('login.failed'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Box
      component="main"
      style={{
        minHeight: '100dvh',
        display: 'flex',
        alignItems: 'center',
        paddingBlock: 24,
        background: 'var(--canvas)',
      }}
    >
      <Container size="lg" w="100%">
        <SimpleGrid cols={{ base: 1, md: 2 }} spacing="xl" style={{ alignItems: 'stretch' }}>
          <Paper
            p={{ base: 'lg', sm: 'xl' }}
            radius="xl"
            style={{
              background: 'var(--sidebar-bg)',
              display: 'flex',
              flexDirection: 'column',
              justifyContent: 'space-between',
              gap: 32,
            }}
          >
            <Group gap="sm">
              <Logo size={34} />
              <Stack gap={0}>
                <Text fw={700} size="lg">{t('login.brand')}</Text>
                <Text size="xs" c="dimmed">PRIVATE READING WORKSPACE</Text>
              </Stack>
            </Group>

            <Stack gap="sm">
              <Title order={1} fz={{ base: 26, sm: 34 }} lh={1.25}>
                把书源、书架和阅读，留在自己的网络里。
              </Title>
              <Text size="sm" c="dimmed" lh={1.7}>
                一套由你掌控的阅读工作流。搜索、缓存、导出和 Kindle 同步，都从这台服务器出发。
              </Text>
            </Stack>

            <Stack gap="md">
              <SimpleGrid cols={{ base: 1, sm: 3 }} spacing="sm">
                <Paper p="sm" radius="md">
                  <Group gap="xs" wrap="nowrap" align="flex-start">
                    <ThemeIcon variant="light" color="brand" size="md" radius="md">
                      <Icon name="source" size={16} />
                    </ThemeIcon>
                    <Stack gap={2}>
                      <Text size="xs" fw={600}>书源可维护</Text>
                      <Text size="xs" c="dimmed">导入、校验与登录</Text>
                    </Stack>
                  </Group>
                </Paper>
                <Paper p="sm" radius="md">
                  <Group gap="xs" wrap="nowrap" align="flex-start">
                    <ThemeIcon variant="light" color="brand" size="md" radius="md">
                      <Icon name="library" size={16} />
                    </ThemeIcon>
                    <Stack gap={2}>
                      <Text size="xs" fw={600}>书架可沉淀</Text>
                      <Text size="xs" c="dimmed">进度、分组与阅读</Text>
                    </Stack>
                  </Group>
                </Paper>
                <Paper p="sm" radius="md">
                  <Group gap="xs" wrap="nowrap" align="flex-start">
                    <ThemeIcon variant="light" color="gold" size="md" radius="md">
                      <Icon name="device" size={16} />
                    </ThemeIcon>
                    <Stack gap={2}>
                      <Text size="xs" fw={600}>Kindle 可同步</Text>
                      <Text size="xs" c="dimmed">上架、推送与回读</Text>
                    </Stack>
                  </Group>
                </Paper>
              </SimpleGrid>
              <Text size="xs" c="dimmed">局域网私有部署 · 数据仅保存在你的服务器</Text>
            </Stack>
          </Paper>

          <Paper
            component="form"
            onSubmit={submit}
            p={{ base: 'lg', sm: 'xl' }}
            radius="xl"
            shadow="sm"
            style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center' }}
          >
            <Stack gap="lg" maw={400} w="100%" mx="auto">
              <Stack gap={4}>
                <Text size="xs" fw={700} c="brand" tt="uppercase" lts={1.2}>
                  Admin Access
                </Text>
                <Title order={2} fz={24}>{t('login.title')}</Title>
                <Text size="sm" c="dimmed">{t('login.desc')}</Text>
              </Stack>

              <PasswordInput
                autoFocus
                size="md"
                label={t('login.password')}
                placeholder={t('login.passwordPlaceholder')}
                value={password}
                onChange={event => setPassword(event.currentTarget.value)}
                leftSection={<Icon name="key" size={16} />}
                required
              />

              {error && (
                <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
                  {error}
                </Alert>
              )}

              <Button type="submit" size="md" fullWidth loading={busy}>
                {busy ? t('login.submitting') : t('login.submit')}
              </Button>
            </Stack>
          </Paper>
        </SimpleGrid>
      </Container>
    </Box>
  )
}
