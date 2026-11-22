import { useState } from 'react'
import {
  Alert,
  Badge,
  Button,
  Code,
  Divider,
  FileButton,
  Group,
  Modal,
  Paper,
  PasswordInput,
  ScrollArea,
  SimpleGrid,
  Stack,
  Tabs,
  Text,
  TextInput,
  ThemeIcon,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import {
  api,
  type BackupImportSummary,
  type ExternalWebDavBackup,
  type ExternalWebDavConfig,
} from './api'
import { Icon } from './icons'

type Props = {
  theme: string
  onClose: () => void
  onImported: (summary: BackupImportSummary) => void
}

type Mode = 'file' | 'webdav'

const CONNECTION_STORAGE_KEY = 'legado-config-import-connection-v1'
const MAX_ZIP_BYTES = 256 * 1024 * 1024

function defaultConnection(): ExternalWebDavConfig {
  const fallback: ExternalWebDavConfig = {
    url: 'https://dav.jianguoyun.com/dav/',
    username: '',
    password: '',
    directory: 'legado',
  }
  try {
    const saved = JSON.parse(localStorage.getItem(CONNECTION_STORAGE_KEY) ?? 'null') as Partial<ExternalWebDavConfig> | null
    if (!saved) return fallback
    return {
      url: typeof saved.url === 'string' ? saved.url : fallback.url,
      username: typeof saved.username === 'string' ? saved.username : '',
      password: '',
      directory: typeof saved.directory === 'string' ? saved.directory : fallback.directory,
    }
  } catch {
    return fallback
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function formatDate(value: number): string {
  if (!value) return ''
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleString('zh-CN')
}

export function ConfigImportModal({ onClose, onImported }: Props) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<Mode>('file')
  const [selectedFile, setSelectedFile] = useState<File | null>(null)
  const [connection, setConnection] = useState<ExternalWebDavConfig>(defaultConnection)
  const [files, setFiles] = useState<ExternalWebDavBackup[]>([])
  const [rootUrl, setRootUrl] = useState('')
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [summary, setSummary] = useState<BackupImportSummary | null>(null)

  const updateConnection = (patch: Partial<ExternalWebDavConfig>) => {
    setConnection(previous => {
      const next = { ...previous, ...patch }
      try {
        localStorage.setItem(CONNECTION_STORAGE_KEY, JSON.stringify({
          url: next.url,
          username: next.username,
          directory: next.directory,
        }))
      } catch {
        // Private browsing can reject storage without preventing the import.
      }
      return next
    })
  }

  const finishImport = (result: BackupImportSummary) => {
    setSummary(result)
    setError('')
    onImported(result)
  }

  const importFile = async () => {
    if (!selectedFile) {
      setError(t('webdav.chooseZipFirst', '请先选择备份 ZIP'))
      return
    }
    if (selectedFile.size > MAX_ZIP_BYTES) {
      setError(t('webdav.zipTooLarge', '备份 ZIP 超过 256 MiB'))
      return
    }
    if (!window.confirm(t('webdav.confirmFileImport', {
      name: selectedFile.name,
      defaultValue: `导入“${selectedFile.name}”中的 Android 配置吗？现有数据会按 Android 的合并规则更新。`,
    }))) return
    setBusy('file')
    setSummary(null)
    setError('')
    try {
      finishImport(await api.importBackupFile(selectedFile))
    } catch (importError) {
      setError(errorMessage(importError, t('webdav.backupImportFailed', '备份导入失败')))
    } finally {
      setBusy('')
    }
  }

  const loadRemoteFiles = async () => {
    if (!connection.url.trim()) {
      setError(t('webdav.urlRequired', '请填写 WebDAV 地址'))
      return
    }
    setBusy('list')
    setError('')
    setSummary(null)
    try {
      const result = await api.listExternalWebDavBackups(connection)
      setFiles(result.files)
      setRootUrl(result.rootUrl)
    } catch (listError) {
      setFiles([])
      setRootUrl('')
      setError(errorMessage(listError, t('webdav.readStatusFailed', '读取 WebDAV 失败')))
    } finally {
      setBusy('')
    }
  }

  const importRemoteFile = async (file: ExternalWebDavBackup) => {
    if (!window.confirm(t('webdav.confirmRemoteImport', {
      name: file.name,
      defaultValue: `从 WebDAV 导入“${file.name}”吗？现有数据会按 Android 的合并规则更新。`,
    }))) return
    setBusy(file.href)
    setSummary(null)
    setError('')
    try {
      finishImport(await api.importExternalWebDavBackup(connection, file.href))
    } catch (importError) {
      setError(errorMessage(importError, t('webdav.backupImportFailed', '备份导入失败')))
    } finally {
      setBusy('')
    }
  }

  return (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      title={
        <Stack gap={2}>
          <Text fw={700} size="lg">{t('header.webdavTitle', 'Android 备份导入')}</Text>
          <Text size="xs" c="dimmed">
            {t('webdav.importIntro', '从本地 ZIP 或任意外部 WebDAV 恢复书源、规则、书架、进度、分组和书签。')}
          </Text>
        </Stack>
      }
    >
      <Stack gap="md">
        <Tabs
          value={mode}
          onChange={value => {
            setMode((value as Mode) || 'file')
            setError('')
            setSummary(null)
          }}
        >
          <Tabs.List>
            <Tabs.Tab value="file" leftSection={<Icon name="importFile" size={15} />}>
              {t('webdav.localZip', '本地 ZIP')}
            </Tabs.Tab>
            <Tabs.Tab value="webdav" leftSection={<Icon name="cloudDownload" size={15} />}>
              {t('webdav.externalWebdav', '外部 WebDAV')}
            </Tabs.Tab>
          </Tabs.List>

          <Alert mt="md" variant="light" color="brand" icon={<Icon name="bookOpen" size={16} />}>
            {t('webdav.supportedData', '当前会导入：书源及分组、替换规则、在线书架、阅读进度、书架分组和书签。手机本机文件会被跳过。')}
          </Alert>

          <Tabs.Panel value="file" pt="md">
            <Stack gap="md">
              <Paper p="md" style={{ background: 'var(--surface-muted)' }}>
                <Group justify="space-between" wrap="nowrap" gap="md">
                  <Group gap="sm" wrap="nowrap" style={{ minWidth: 0 }}>
                    <ThemeIcon size="lg" variant="light" color="brand">
                      <Icon name="file" size={18} />
                    </ThemeIcon>
                    <Stack gap={2} style={{ minWidth: 0 }}>
                      <Text size="sm" fw={600} truncate>
                        {selectedFile?.name ?? t('webdav.chooseZip', '选择一个 Android 备份 ZIP')}
                      </Text>
                      <Text size="xs" c="dimmed">
                        {selectedFile
                          ? `${formatBytes(selectedFile.size)} · ${t('webdav.readyToImport', '可以导入')}`
                          : t('webdav.zipOnlyWarning', '只支持上传 Android Legado 备份 ZIP。')}
                      </Text>
                    </Stack>
                  </Group>
                  <FileButton
                    accept=".zip,application/zip,application/x-zip-compressed"
                    disabled={Boolean(busy)}
                    onChange={file => {
                      setSelectedFile(file)
                      setError('')
                      setSummary(null)
                    }}
                  >
                    {props => (
                      <Button {...props} variant="default" leftSection={<Icon name="upload" size={15} />}>
                        {t('webdav.chooseFile', '选择文件')}
                      </Button>
                    )}
                  </FileButton>
                </Group>
              </Paper>
              <Button
                fullWidth
                loading={busy === 'file'}
                disabled={!selectedFile || Boolean(busy)}
                leftSection={<Icon name="importFile" size={16} />}
                onClick={() => void importFile()}
              >
                {busy === 'file' ? t('webdav.importing', '导入中…') : t('webdav.startImport', '开始导入')}
              </Button>
            </Stack>
          </Tabs.Panel>

          <Tabs.Panel value="webdav" pt="md">
            <Stack gap="sm">
              <TextInput
                label={t('webdav.url', 'WebDAV 地址')}
                type="url"
                value={connection.url}
                placeholder="https://dav.jianguoyun.com/dav/"
                onChange={event => updateConnection({ url: event.target.value })}
              />
              <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
                <TextInput
                  label={t('webdav.username', '用户名')}
                  autoComplete="username"
                  value={connection.username}
                  onChange={event => updateConnection({ username: event.target.value })}
                />
                <PasswordInput
                  label={t('webdav.password', '密码')}
                  autoComplete="current-password"
                  value={connection.password}
                  onChange={event => updateConnection({ password: event.target.value })}
                />
              </SimpleGrid>
              <TextInput
                label={t('webdav.directory', '子目录')}
                value={connection.directory}
                placeholder="legado"
                onChange={event => updateConnection({ directory: event.target.value })}
              />
              <Text size="xs" c="dimmed">
                {t('webdav.credentialNote', 'WebDAV 密码只用于本次请求，不会保存到服务器；地址、用户名和子目录会保存在当前浏览器。')}
              </Text>
              <Button
                fullWidth
                loading={busy === 'list'}
                disabled={Boolean(busy)}
                leftSection={<Icon name="refresh" size={15} />}
                onClick={() => void loadRemoteFiles()}
              >
                {busy === 'list' ? t('webdav.loadingDirectory', '正在读取备份目录…') : t('webdav.readBackups', '读取备份列表')}
              </Button>
              {rootUrl && (
                <Group gap="xs" wrap="nowrap">
                  <Text size="xs" c="dimmed">{t('webdav.scanningDirectory', '扫描目录')}：</Text>
                  <Code style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{rootUrl}</Code>
                </Group>
              )}
              {(files.length > 0 || rootUrl) && (
                <ScrollArea mah={220}>
                  <Stack gap="xs">
                    {files.map(file => (
                      <Paper key={file.href} p="xs">
                        <Group justify="space-between" wrap="nowrap" gap="sm">
                          <Group gap="xs" wrap="nowrap" style={{ minWidth: 0 }}>
                            <ThemeIcon variant="light" color="brand" size="md">
                              <Icon name="file" size={15} />
                            </ThemeIcon>
                            <Stack gap={1} style={{ minWidth: 0 }}>
                              <Text size="sm" fw={600} truncate title={file.name}>{file.name}</Text>
                              <Text size="xs" c="dimmed">
                                {formatBytes(file.size)}{file.modifiedAt ? ` · ${formatDate(file.modifiedAt)}` : ''}
                              </Text>
                            </Stack>
                          </Group>
                          <Button
                            size="xs"
                            variant="light"
                            loading={busy === file.href}
                            disabled={Boolean(busy)}
                            leftSection={<Icon name="importFile" size={14} />}
                            onClick={() => void importRemoteFile(file)}
                          >
                            {busy === file.href ? t('webdav.importing', '导入中…') : t('common.import', '导入')}
                          </Button>
                        </Group>
                      </Paper>
                    ))}
                    {rootUrl && files.length === 0 && (
                      <Text size="sm" c="dimmed" ta="center" py="md">
                        {t('webdav.noBackups', '该目录下没有 backup 开头的 ZIP 备份。')}
                      </Text>
                    )}
                  </Stack>
                </ScrollArea>
              )}
            </Stack>
          </Tabs.Panel>
        </Tabs>

        {error && (
          <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
            {error}
          </Alert>
        )}

        {summary && (
          <Paper p="md" style={{ background: 'var(--success-soft)', borderColor: 'var(--success)' }}>
            <Stack gap="xs">
              <Group gap="xs">
                <ThemeIcon color="teal" variant="filled" size="sm" radius="xl">
                  <Icon name="check" size={12} />
                </ThemeIcon>
                <Text size="sm" fw={700}>{t('webdav.importComplete', '配置导入完成')}</Text>
                <Text size="xs" c="dimmed">{t('webdav.importCompleteHint', '书源、书架和分组已在后台刷新。')}</Text>
              </Group>
              <Group gap="xs" wrap="wrap">
                <Badge variant="white" color="dark">{t('webdav.sourcesCount', '书源')} {summary.sources + summary.sourcesUpdated}</Badge>
                <Badge variant="white" color="dark">{t('webdav.rulesCount', '替换规则')} {summary.rules + summary.rulesUpdated}</Badge>
                <Badge variant="white" color="dark">{t('webdav.booksCount', '书籍')} {summary.books + summary.booksUpdated}</Badge>
                <Badge variant="white" color="dark">{t('webdav.progressCount', '阅读进度')} {summary.progress}</Badge>
                <Badge variant="white" color="dark">{t('webdav.bookmarksCount', '书签')} {summary.bookmarks}</Badge>
                <Badge variant="white" color="gray">{t('webdav.skippedLocalCount', '跳过本机书')} {summary.skippedLocal}</Badge>
              </Group>
              {(summary.coversQueued > 0 || summary.coversFailed > 0) && (
                <Text size="xs" c="dimmed">
                  {summary.coversQueued > 0 && t('webdav.coversQueued', '{{count}} 本书的封面已转入后台补抓。', { count: summary.coversQueued })}
                  {summary.coversFailed > 0 && t('webdav.coversFailed', ' {{count}} 张封面补抓失败，不影响阅读。', { count: summary.coversFailed })}
                </Text>
              )}
            </Stack>
          </Paper>
        )}

        <Divider />

        <Group justify="space-between" gap="xs">
          <Text size="xs" c="dimmed">{t('webdav.safeMergeHint', '导入采用增量合并，不删除 Server 中备份包未包含的数据。')}</Text>
          <Button variant="default" onClick={onClose}>{t('common.close', '关闭')}</Button>
        </Group>
      </Stack>
    </Modal>
  )
}
