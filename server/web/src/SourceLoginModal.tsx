import React, { useState, useEffect, useCallback, useRef } from 'react'
import {
  ActionIcon,
  Alert,
  Badge,
  Box,
  Button,
  Center,
  Group,
  Loader,
  Menu,
  Modal,
  Paper,
  PasswordInput,
  NativeSelect,
  Stack,
  Switch,
  Text,
  Textarea,
  TextInput,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, SourceLoginUiItem, SourceLoginUiResponse } from './api'
import type { SourceLoginBookRefresh, SourceLoginContext } from './api'
import { Icon } from './icons'
import { SourceWebViewModal } from './SourceWebViewModal'
import { NetworkImportModal } from './NetworkImportModal'
import { isInlineBrowserTarget } from './sourceSettingsResult'

const isBrowserCancellation = (error?: string) =>
  Boolean(error && /(浏览器.*取消|取消.*浏览器)/.test(error))

const isFailureMessage = (message: string) =>
  /(失败|错误|无法|未获取|未登录|已失效|请先登录|取消)/.test(message)

interface SourceLoginModalProps {
  sourceId: string
  sourceName?: string
  context?: SourceLoginContext
  onBookRefresh?: (refresh: SourceLoginBookRefresh, context: SourceLoginContext) => void
  onClose: () => void
  onToast: (message: string, type?: 'info' | 'success' | 'error') => void
}

export const SourceLoginModal: React.FC<SourceLoginModalProps> = ({
  sourceId,
  sourceName,
  context,
  onBookRefresh,
  onClose,
  onToast,
}) => {
  const { t } = useTranslation()
  const [loading, setLoading] = useState(true)
  const [executing, setExecuting] = useState(false)
  const [executingAction, setExecutingAction] = useState<string | null>(null)
  const [uiResponse, setUiResponse] = useState<SourceLoginUiResponse | null>(null)
  const [formData, setFormData] = useState<Record<string, string>>({})
  const [menuOpen, setMenuOpen] = useState(false)
  const [headerEditOpen, setHeaderEditOpen] = useState(false)
  const [headerEditText, setHeaderEditText] = useState('')
  const [cookieModalOpen, setCookieModalOpen] = useState(false)
  const [cookieInputText, setCookieInputText] = useState('')
  const [webViewOpen, setWebViewOpen] = useState(false)
  const [webViewStartUrl, setWebViewStartUrl] = useState<string | undefined>(undefined)
  /** 内置浏览器里点了「更新书源」线路后要导入的地址；非 null 即打开网络导入弹窗。 */
  const [networkImportUrl, setNetworkImportUrl] = useState<string | null>(null)
  const active = useRef(false)

  const loadLoginUi = useCallback(async () => {
    try {
      setLoading(true)
      const res = await api.getSourceLoginUi(sourceId)
      setUiResponse(res)
      setHeaderEditText(res.loginHeader || '')
      const initialData: Record<string, string> = { ...(res.loginInfo || {}) }
      res.loginUi.forEach(item => {
        const key = item.key || item.name
        if (key && initialData[key] === undefined && item.default) {
          initialData[key] = item.default
        }
      })
      setFormData(initialData)
    } catch (err: any) {
      onToast(err.message || t('source.loadLoginUiFailed', '获取登录界面失败'), 'error')
    } finally {
      setLoading(false)
    }
  }, [sourceId, onToast, t])

  useEffect(() => {
    active.current = true
    loadLoginUi()
    return () => { active.current = false }
  }, [loadLoginUi])

  /** 用户手动打开内置浏览器（不带触发动作），入口地址交给书源配置决定 */
  const openBuiltInBrowser = useCallback(() => {
    setWebViewStartUrl(undefined)
    setWebViewOpen(true)
  }, [])

  const handleInputChange = (key: string, val: string) => {
    setFormData(prev => ({ ...prev, [key]: val }))
  }

  const executeAction = async (action: string, isLongClick = false) => {
    const result = await api.executeSourceLoginAction(sourceId, action, formData, isLongClick, context)
    if (active.current && result.bookRefresh && context) {
      onBookRefresh?.(result.bookRefresh, context)
      result.bookRefresh.errors?.forEach(error => onToast(error, 'error'))
    }
    return result
  }

  const handleAction = async (actionCode?: string, isLongClick = false, allowBuiltInBrowser = true) => {
    if (!actionCode && actionCode !== '') return
    try {
      setExecuting(true)
      setExecutingAction(actionCode)
      const trimmed = actionCode.trim()
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        window.open(trimmed, '_blank', 'noopener,noreferrer')
        return
      }

      const res = await executeAction(actionCode, isLongClick)
      if (res.error) {
        // 用户主动结束内置浏览器不是脚本故障，要和真正的书源执行异常区分开。
        if (isBrowserCancellation(res.error)) {
          onToast(res.error, 'info')
        } else {
          // 书源脚本失败时必须显式告知，否则按钮会「看起来成功但毫无反应」
          onToast(t('source.scriptExecFailed', { error: res.error, defaultValue: `书源脚本执行失败：${res.error}` }), 'error')
        }
      } else if (res.toastMessages && res.toastMessages.length > 0) {
        res.toastMessages.forEach(msg => onToast(msg, res.success && !isFailureMessage(msg) ? 'success' : 'error'))
      } else if (res.success && !res.bookRefresh?.errors?.length) {
        onToast(t('source.operationSuccess', '操作执行成功'), 'success')
      }

      if (res.openUrl) {
        // 书源 JS 通过 java.startBrowserAwait(url) 请求打开网页：在本应用内置浏览器中打开，
        // 而不是弹到外部标签页，这样登录产生的 Cookie 能直接落到书源 Credential 里。
        // 书源自生成的内联页（data:text/html;base64,…）只能由代理层在 iframe 里渲染——
        // 直接 window.open 只会开出一个空白新标签，且拿不到任何回传结果。
        if (allowBuiltInBrowser || isInlineBrowserTarget(res.openUrl)) {
          setWebViewStartUrl(res.openUrl)
          setWebViewOpen(true)
        } else {
          window.open(res.openUrl, '_blank', 'noopener,noreferrer')
        }
      }
      if (res.copyText) {
        await navigator.clipboard.writeText(res.copyText)
        onToast(t('source.copiedToClipboardWithText', { text: res.copyText, defaultValue: `已复制到剪贴板: ${res.copyText}` }), 'info')
      }
      if (res.updatedLoginInfo) {
        setFormData(prev => ({ ...prev, ...res.updatedLoginInfo }))
      }
      if (res.reRenderUi) {
        await loadLoginUi()
      }
    } catch (err: any) {
      onToast(err.message || t('source.executeActionFailed', '执行操作失败'), 'error')
    } finally {
      setExecuting(false)
      setExecutingAction(null)
    }
  }

  const handleSaveAndLogin = async () => {
    try {
      setExecuting(true)
      setExecutingAction('login(true)')
      await api.saveSourceLoginInfo(sourceId, formData)
      const res = await executeAction('login(true)')
      if (res.error) {
        if (isBrowserCancellation(res.error)) {
          onToast(res.error, 'info')
        } else {
          onToast(t('source.scriptExecFailed', { error: res.error, defaultValue: `书源脚本执行失败：${res.error}` }), 'error')
        }
      } else if (res.toastMessages && res.toastMessages.length > 0) {
        res.toastMessages.forEach(msg => onToast(msg, res.success && !isFailureMessage(msg) ? 'success' : 'error'))
      } else {
        onToast(t('source.loginInfoSavedAndAttempting', '登录信息已保存并尝试登录'), 'success')
      }
      if (res.openUrl) {
        setWebViewStartUrl(res.openUrl)
        setWebViewOpen(true)
      }
      if (res.copyText) {
        await navigator.clipboard.writeText(res.copyText)
      }
      if (res.updatedLoginInfo) {
        setFormData(prev => ({ ...prev, ...res.updatedLoginInfo }))
      }
      if (res.reRenderUi) {
        await loadLoginUi()
      }
    } catch (err: any) {
      onToast(err.message || t('source.saveOrLoginFailed', '保存或登录失败'), 'error')
    } finally {
      setExecuting(false)
      setExecutingAction(null)
    }
  }

  const handleCopyLoginHeader = async () => {
    const header = uiResponse?.loginHeader
    if (!header) {
      onToast(t('source.noLoginHeader', '当前书源无登录头'), 'info')
      return
    }
    await navigator.clipboard.writeText(header)
    onToast(t('source.loginHeaderCopied', '登录头已复制到剪贴板'), 'success')
    setMenuOpen(false)
  }

  const handleSaveHeader = async () => {
    try {
      setExecuting(true)
      await api.saveSourceLoginHeader(sourceId, headerEditText.trim())
      onToast(t('source.loginHeaderUpdatedSuccess', '登录头已成功更新并保存'), 'success')
      setHeaderEditOpen(false)
      await loadLoginUi()
    } catch (err: any) {
      onToast(err.message || t('source.saveLoginHeaderFailed', '保存登录头失败'), 'error')
    } finally {
      setExecuting(false)
    }
  }

  const handleSaveCookie = async () => {
    if (!cookieInputText.trim()) {
      onToast(t('source.enterCookiePrompt', '请输入 Cookie 内容'), 'error')
      return
    }
    try {
      setExecuting(true)
      await api.saveSourceCookie(sourceId, cookieInputText.trim())
      onToast(t('source.cookieSavedSuccess', 'Cookie 已成功保存并关联到书源'), 'success')
      setCookieModalOpen(false)
      setCookieInputText('')
      await loadLoginUi()
    } catch (err: any) {
      onToast(err.message || t('source.saveCookieFailed', '保存 Cookie 失败'), 'error')
    } finally {
      setExecuting(false)
    }
  }

  const handleDeleteLoginHeader = async () => {
    if (!confirm(t('source.confirmDeleteLoginHeader', '确定删除此书源保存的登录头吗？'))) return
    try {
      await api.clearSourceLoginHeader(sourceId)
      onToast(t('source.loginHeaderDeleted', '登录头已删除'), 'success')
      setMenuOpen(false)
      loadLoginUi()
    } catch (err: any) {
      onToast(err.message || t('source.deleteLoginHeaderFailed', '删除登录头失败'), 'error')
    }
  }

  const handleClearLoginInfo = async () => {
    if (!confirm(t('source.confirmClearLoginInfo', '确定清空此书源的所有登录输入信息吗？'))) return
    try {
      await api.clearSourceLoginInfo(sourceId)
      setFormData({})
      onToast(t('source.loginInfoCleared', '登录信息已清空'), 'success')
      setMenuOpen(false)
    } catch (err: any) {
      onToast(err.message || t('source.clearLoginInfoFailed', '清空登录信息失败'), 'error')
    }
  }

  const renderControl = (item: SourceLoginUiItem, index: number) => {
    const key = item.key || item.name
    const label = item.viewName || item.name
    const type = (item.type || 'text').toLowerCase()
    const value = formData[key] ?? ''

    const basisPercent = item.style?.layout_flexBasisPercent ?? -1
    let flexStyle: React.CSSProperties = {}
    if (basisPercent > 0) {
      if (basisPercent >= 0.9) {
        flexStyle = { flex: '1 1 100%', width: '100%' }
      } else if (basisPercent >= 0.4 && basisPercent <= 0.6) {
        flexStyle = { flex: '1 1 calc(50% - 8px)', minWidth: '180px' }
      } else {
        flexStyle = { flex: `1 1 ${Math.round(basisPercent * 100)}%` }
      }
    } else {
      flexStyle = { flex: item.style?.layout_flexGrow ? `${item.style.layout_flexGrow} 1 auto` : '1 1 100%', width: '100%' }
    }

    if (item.style?.layout_wrapBefore) {
      flexStyle.breakBefore = 'always'
    }

    if (type === 'button') {
      const isThisAction = executing && executingAction === item.action
      return (
        <Box key={`${key}-${index}`} style={flexStyle}>
          <Button
            fullWidth
            variant="light"
            color="brand"
            loading={isThisAction}
            disabled={executing}
            onClick={() => handleAction(item.action, false)}
            onContextMenu={e => {
              e.preventDefault()
              handleAction(item.action, true)
            }}
          >
            {label}
          </Button>
        </Box>
      )
    }

    if (type === 'toggle' || type === 'switch' || type === 'checkbox') {
      const isChecked = value === 'true' || value === '1'
      return (
        <Paper key={`${key}-${index}`} style={flexStyle} p="xs" withBorder radius="md">
          <Group justify="space-between">
            <Text size="sm" fw={500}>{label}</Text>
            <Switch
              aria-label={label}
              checked={isChecked}
              onChange={e => handleInputChange(key, e.target.checked ? 'true' : 'false')}
            />
          </Group>
        </Paper>
      )
    }

    if (type === 'select' || type === 'dropdown') {
      const options = Array.from(new Set(item.options || (item.chars ? item.chars.filter((c): c is string => c !== null) : [])))
      return (
        <Box key={`${key}-${index}`} style={flexStyle}>
          <NativeSelect
            label={label}
            value={value}
            onChange={e => handleInputChange(key, e.currentTarget.value)}
            data={options}
          />
        </Box>
      )
    }

    if (type === 'label' || type === 'textlabel') {
      return (
        <Alert key={`${key}-${index}`} style={flexStyle} variant="light" color="gray" p="xs">
          <Text size="xs">{item.hint || item.default || label}</Text>
        </Alert>
      )
    }

    const isPassword = type === 'password'
    if (isPassword) {
      return (
        <Box key={`${key}-${index}`} style={flexStyle}>
          <PasswordInput
            label={label}
            value={value}
            placeholder={item.hint || item.default || t('source.pleaseInput', { label, defaultValue: `请输入${label}` })}
            onChange={e => handleInputChange(key, e.target.value)}
          />
        </Box>
      )
    }

    return (
      <Box key={`${key}-${index}`} style={flexStyle}>
        <TextInput
          label={label}
          value={value}
          placeholder={item.hint || item.default || t('source.pleaseInput', { label, defaultValue: `请输入${label}` })}
          onChange={e => handleInputChange(key, e.target.value)}
        />
      </Box>
    )
  }

  const hasChildModal = headerEditOpen || cookieModalOpen || webViewOpen || networkImportUrl !== null
  const displayName = uiResponse?.sourceName || sourceName

  return (
    <>
      <Modal
        opened
        onClose={onClose}
        size="lg"
        zIndex={310}
        withCloseButton={false}
        closeOnEscape={!hasChildModal}
        closeOnClickOutside={!hasChildModal}
        trapFocus={!hasChildModal}
        overlayProps={webViewOpen ? { blur: 0, backgroundOpacity: 0.45 } : undefined}
        padding="lg"
      >
        <Stack gap="md">
          <Group justify="space-between" align="flex-start" wrap="nowrap" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
            <Stack gap={4} style={{ minWidth: 0 }}>
              <Group gap="xs">
                <Icon name="key" size={18} />
                <Text fw={700} size="lg" lineClamp={1}>
                  {displayName
                    ? t('source.loginSourceTitle', { name: displayName, defaultValue: '登录书源 {{name}}' })
                    : t('source.loginButton', '书源登录')}
                </Text>
              </Group>
              {uiResponse?.sourceVariable && (
                <Badge variant="light" color="gray" size="sm" title={uiResponse.sourceVariable}>
                  {t('source.associatedVariable', '关联变量: {{name}}', { name: uiResponse.sourceVariable })}
                </Badge>
              )}
            </Stack>

            <Group gap={6} wrap="nowrap">
              <Tooltip label={t('source.loginWithBrowserRecommended', '用内置浏览器登录（推荐）')}>
                <ActionIcon variant="light" color="brand" onClick={openBuiltInBrowser} aria-label={t('source.loginWithBrowserRecommended', '用内置浏览器登录（推荐）')}>
                  <Icon name="globe" size={16} />
                </ActionIcon>
              </Tooltip>
              <Tooltip label={t('source.saveAndLogin', '保存并登录')}>
                <ActionIcon
                  variant="filled"
                  color="brand"
                  loading={executing && executingAction === 'login(true)'}
                  disabled={executing || loading}
                  onClick={handleSaveAndLogin}
                  aria-label={t('source.saveAndLogin', '保存并登录')}
                >
                  <Icon name="check" size={16} />
                </ActionIcon>
              </Tooltip>
              <Menu opened={menuOpen} onChange={setMenuOpen} position="bottom-end" withinPortal>
                <Tooltip label={t('source.moreOptions', '更多选项')}>
                  <Menu.Target>
                    <ActionIcon variant="subtle" color="gray" aria-label={t('source.moreOptions', '更多选项')}>
                      <Icon name="more" size={16} />
                    </ActionIcon>
                  </Menu.Target>
                </Tooltip>
                <Menu.Dropdown>
                  <Menu.Item
                    leftSection={<Icon name="edit" size={14} />}
                    onClick={() => {
                      setHeaderEditText(uiResponse?.loginHeader || '')
                      setHeaderEditOpen(true)
                      setMenuOpen(false)
                    }}
                  >
                    {t('source.editLoginHeader', '填入 / 查看登录头')}
                  </Menu.Item>
                  <Menu.Item
                    leftSection={<Icon name="cookie" size={14} />}
                    onClick={() => {
                      setCookieModalOpen(true)
                      setMenuOpen(false)
                    }}
                  >
                    {t('source.quickFillCookie', '快捷填入 Cookie')}
                  </Menu.Item>
                  {uiResponse?.loginHeader && (
                    <Menu.Item leftSection={<Icon name="copy" size={14} />} onClick={handleCopyLoginHeader}>
                      {t('source.copyLoginHeader', '复制登录头')}
                    </Menu.Item>
                  )}
                  <Menu.Divider />
                  <Menu.Item color="red" leftSection={<Icon name="trash" size={14} />} onClick={handleDeleteLoginHeader}>
                    {t('source.deleteLoginHeader', '删除登录头')}
                  </Menu.Item>
                  <Menu.Item color="red" leftSection={<Icon name="close" size={14} />} onClick={handleClearLoginInfo}>
                    {t('source.clearLoginInfo', '清空登录信息')}
                  </Menu.Item>
                </Menu.Dropdown>
              </Menu>
              <Tooltip label={t('common.close', '关闭')}>
                <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
                  <Icon name="close" size={16} />
                </ActionIcon>
              </Tooltip>
            </Group>
          </Group>

          {loading ? (
            <Center py="xl">
              <Group gap="sm">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">{t('source.loadingLoginUi', '正在加载登录界面...')}</Text>
              </Group>
            </Center>
          ) : !uiResponse?.loginUi || uiResponse.loginUi.length === 0 ? (
            <Stack gap="md">
              <Group justify="space-between" wrap="wrap" gap="xs">
                <Text size="sm" c="dimmed">
                  {t('source.noVisualLoginFormHint', '此书源未定义可视化登录表单，请直接填入 Cookie / 凭据：')}
                </Text>
                {uiResponse?.loginUrl && (
                  <Button
                    size="xs"
                    variant="light"
                    leftSection={<Icon name="globe" size={14} />}
                    onClick={openBuiltInBrowser}
                  >
                    {t('source.loginWithBrowser', '用内置浏览器登录')}
                  </Button>
                )}
              </Group>

              <Paper p="md" withBorder radius="md">
                <Stack gap="xs">
                  <Group justify="space-between" wrap="wrap" gap="xs">
                    <Group gap={6}>
                      <Icon name="cookie" size={15} />
                      <Text size="xs" fw={600}>
                        {t('source.pasteCookieToken', '粘贴 Cookie / Token (支持 JSON / 键值对)')}
                      </Text>
                    </Group>
                    <Text size="xs" c="dimmed">
                      {t('source.cookieEditorSupport', '支持 Cookie-Editor 导出的 JSON')}
                    </Text>
                  </Group>
                  <Textarea
                    rows={5}
                    value={cookieInputText}
                    placeholder={t('source.cookiePlaceholder', '直接粘贴 Cookie 字符串（k1=v1; k2=v2）或 Cookie-Editor 导出的 JSON 数组：\n[{"name":"session_id","value":"..."},{"name":"token","value":"..."}]')}
                    onChange={e => setCookieInputText(e.target.value)}
                    styles={{ input: { fontFamily: 'var(--mantine-font-family-monospace)' } }}
                  />
                  <Group justify="space-between" wrap="wrap" gap="xs">
                    <div>
                      {uiResponse?.loginHeader && (
                        <Button
                          size="xs"
                          variant="subtle"
                          color="red"
                          leftSection={<Icon name="trash" size={14} />}
                          onClick={handleDeleteLoginHeader}
                        >
                          {t('source.clearSavedCredentials', '清除已存凭据')}
                        </Button>
                      )}
                    </div>
                    <Button
                      loading={executing}
                      disabled={!cookieInputText.trim()}
                      onClick={handleSaveCookie}
                    >
                      {executing ? t('source.saving', '保存中...') : t('source.saveCookie', '保存 Cookie')}
                    </Button>
                  </Group>
                </Stack>
              </Paper>

              {uiResponse?.loginHeader && (
                <Alert
                  color="teal"
                  variant="light"
                  icon={<Icon name="checkCircle" size={16} />}
                  title={t('source.hasPersistedLoginHeader', '当前书源已持久化登录头 (Login Header)')}
                >
                  <Text
                    size="xs"
                    c="dimmed"
                    style={{ wordBreak: 'break-all', fontFamily: 'var(--mantine-font-family-monospace)', maxHeight: 72, overflowY: 'auto' }}
                  >
                    {uiResponse.loginHeader}
                  </Text>
                </Alert>
              )}
            </Stack>
          ) : (
            <form
              onSubmit={e => {
                e.preventDefault()
                handleSaveAndLogin()
              }}
            >
              <Stack gap="md">
                <Button
                  fullWidth
                  leftSection={<Icon name="globe" size={16} />}
                  onClick={openBuiltInBrowser}
                >
                  {t('source.loginWithBrowserRecommended', '用内置浏览器登录（推荐）')}
                </Button>
                <Box style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'flex-end' }}>
                  {uiResponse.loginUi.map((item, idx) => renderControl(item, idx))}
                </Box>
              </Stack>
            </form>
          )}
        </Stack>
      </Modal>

      <Modal
        opened={headerEditOpen}
        onClose={() => setHeaderEditOpen(false)}
        title={t('source.editLoginHeaderModalTitle', '编辑 / 填入登录头 (Login Header)')}
        size="md"
        zIndex={340}
      >
        <Stack gap="sm">
          <Text size="xs" c="dimmed">
            {t('source.editLoginHeaderDesc', '支持 JSON 格式（如 {"Authorization": "Bearer ...", "Cookie": "..."}）或直接文本。')}
          </Text>
          <Textarea
            rows={6}
            value={headerEditText}
            placeholder='{"Authorization": "Bearer ...", "Cookie": "..."}'
            onChange={e => setHeaderEditText(e.target.value)}
            styles={{ input: { fontFamily: 'var(--mantine-font-family-monospace)' } }}
          />
          <Group justify="flex-end" gap="xs">
            <Button variant="default" onClick={() => setHeaderEditOpen(false)}>{t('common.cancel', '取消')}</Button>
            <Button loading={executing} onClick={handleSaveHeader}>{t('source.saveLoginHeader', '保存登录头')}</Button>
          </Group>
        </Stack>
      </Modal>

      <Modal
        opened={cookieModalOpen}
        onClose={() => setCookieModalOpen(false)}
        title={t('source.quickFillCookieModalTitle', '快捷填入 Cookie')}
        size="md"
        zIndex={340}
      >
        <Stack gap="sm">
          <Text size="xs" c="dimmed">
            {t('source.quickFillCookieDesc', '将目标网站登录后的 Cookie 字符串粘贴在下方（服务端将自动按域名持久化合并）：')}
          </Text>
          <Textarea
            rows={5}
            value={cookieInputText}
            placeholder="token=xxxx; uid=12345; session=yyyy"
            onChange={e => setCookieInputText(e.target.value)}
            styles={{ input: { fontFamily: 'var(--mantine-font-family-monospace)' } }}
          />
          <Group justify="flex-end" gap="xs">
            <Button variant="default" onClick={() => setCookieModalOpen(false)}>{t('common.cancel', '取消')}</Button>
            <Button loading={executing} onClick={handleSaveCookie}>{t('source.saveCookie', '保存 Cookie')}</Button>
          </Group>
        </Stack>
      </Modal>

      {webViewOpen && (
        <SourceWebViewModal
          sourceId={sourceId}
          sourceName={displayName || sourceId}
          startUrl={webViewStartUrl}
          childModalOpen={networkImportUrl !== null}
          onClose={() => setWebViewOpen(false)}
          onToast={onToast}
          onSettingsSaved={() => {
            void loadLoginUi()
          }}
          onLoggedIn={() => {
            void loadLoginUi()
          }}
          onImportOnline={url => setNetworkImportUrl(url)}
        />
      )}

      {networkImportUrl !== null && (
        <NetworkImportModal
          initialUrl={networkImportUrl}
          onClose={() => setNetworkImportUrl(null)}
          onImported={() => { void loadLoginUi() }}
          onToast={onToast}
        />
      )}
    </>
  )
}
