import { FormEvent, useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import {
  ActionIcon,
  Alert,
  Badge,
  Box,
  Button,
  Card,
  Center,
  Checkbox,
  Collapse,
  Divider,
  Grid,
  Group,
  Loader,
  Menu,
  Modal,
  Paper,
  Progress,
  ScrollArea,
  Select,
  SimpleGrid,
  Stack,
  Tabs,
  Text,
  TextInput,
  ThemeIcon,
  Title,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, BookDetails, BookGroup, BookshelfItem, BookshelfRefreshStatus, BookshelfRefreshTarget, Chapter, SearchResult, SearchStreamEvent, SourceSummary, streamSearch } from '../../api'
import { AutomationCenter } from '../../AutomationCenter'
import { BookCover } from '../../BookCover'
import { BookExportModal } from '../../BookExportModal'
import { CacheConcurrencyDialog } from '../../CacheConcurrencyDialog'
import { Icon } from '../../icons'
import { isLocalBook } from '../../localBook'
import { clearOfflineBook, getShelfSnapshot, saveShelfSnapshot } from '../../offlineStorage'
import { ReaderTheme } from '../../readerSettings'
import { cleanAuthor, cleanTitle } from '../../searchFilters'
import { ClearCacheScope, stepsForScope } from '../../shelfClearCache'
import { SHELF_MODAL_SHELF, shelfModalReducer } from '../../shelfModalStack'
import { ShelfKindTag } from '../../ShelfKindTag'
import { sanitizeImageUrl } from '../../sourceImport'
import { SourceLoginModal } from '../../SourceLoginModal'
import { SourceSwitchModal } from '../../SourceSwitchModal'
import { toast } from '../../Toast'
import { readCustomVariable, parseBookVariables } from '../../lib/bookVariables'


function BookInfoEditModal({
  item,
  groups,
  onSaved,
  onClose,
}: {
  item: BookshelfItem
  groups: BookGroup[]
  onSaved: (updated: BookshelfItem) => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [name, setName] = useState(item.name)
  const [author, setAuthor] = useState(item.author || '')
  const [groupName, setGroupName] = useState<string | undefined>(item.groupName)
  const [coverUrl, setCoverUrl] = useState<string | null>(null) // null = keep existing, '' = clear, string = new URL
  const [uploadedCoverKey, setUploadedCoverKey] = useState<string | null>(null)
  const [uploadingCover, setUploadingCover] = useState(false)
  const [alternateSources, setAlternateSources] = useState<SearchResult[]>(item.alternateSources || [])
  // 书籍变量里的 `custom` 值（听书音色/朗读者）。初值来自书架条目携带的 `variable` JSON。
  const [customVariable, setCustomVariable] = useState(() => readCustomVariable(item.variable))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const fileInputRef = useRef<HTMLInputElement | null>(null)

  // In-modal online search completion states
  const [searchOpen, setSearchOpen] = useState(false)
  const [searchKeyword, setSearchKeyword] = useState(item.name)
  const [searching, setSearching] = useState(false)
  const [searchResults, setSearchResults] = useState<SearchResult[]>([])
  const [searchProgress, setSearchProgress] = useState<SearchStreamEvent | null>(null)
  const [searchError, setSearchError] = useState('')
  const searchSocketRef = useRef<WebSocket | null>(null)

  const stopSearch = useCallback(() => {
    if (searchSocketRef.current) {
      searchSocketRef.current.close()
      searchSocketRef.current = null
    }
    setSearching(false)
  }, [])

  useEffect(() => {
    return () => {
      if (searchSocketRef.current) {
        searchSocketRef.current.close()
        searchSocketRef.current = null
      }
    }
  }, [])

  const handleStartSearch = useCallback((overrideKeyword?: string) => {
    const kw = (overrideKeyword ?? searchKeyword).trim()
    if (!kw) {
      setSearchError(t('library.inputKeyword', '请输入搜索关键词'))
      return
    }

    stopSearch()
    setSearching(true)
    setSearchError('')
    setSearchResults([])
    setSearchProgress(null)

    const socket = streamSearch(
      kw,
      undefined,
      event => {
        if (event.type === 'start' || event.type === 'progress' || event.type === 'done') {
          setSearchProgress(event)
        }
        if (event.type === 'results' && event.results.length > 0) {
          setSearchResults(prev => {
            const existingKeys = new Set(prev.map(r => `${r.sourceId}\u0000${r.bookUrl}`))
            const fresh = event.results.filter(r => !existingKeys.has(`${r.sourceId}\u0000${r.bookUrl}`))
            return fresh.length > 0 ? [...prev, ...fresh] : prev
          })
        }
        if (event.type === 'done') {
          setSearching(false)
        }
      },
      err => {
        setSearchError(err)
        setSearching(false)
      },
      () => {
        setSearching(false)
      }
    )
    searchSocketRef.current = socket
  }, [searchKeyword, stopSearch, t])

  const handleApplyCandidate = useCallback((candidate: SearchResult) => {
    if (candidate.author) {
      setAuthor(candidate.author)
    }
    if (candidate.coverUrl) {
      setCoverUrl(candidate.coverUrl)
    }
    // Merge candidate and all search results into alternateSources
    setAlternateSources(prev => {
      const existing = new Set(prev.map(s => `${s.sourceId}\u0000${s.bookUrl}`))
      const toAdd: SearchResult[] = []
      const candKey = `${candidate.sourceId}\u0000${candidate.bookUrl}`
      if (!existing.has(candKey)) {
        toAdd.push(candidate)
        existing.add(candKey)
      }
      for (const r of searchResults) {
        const k = `${r.sourceId}\u0000${r.bookUrl}`
        if (!existing.has(k)) {
          toAdd.push(r)
          existing.add(k)
        }
      }
      return [...toAdd, ...prev]
    })
    toast.success(t('shelf.appliedCandidateInfo', '已应用来自【{{source}}】的书籍信息', { source: candidate.sourceId }))
  }, [searchResults, t])

  const candidateCovers = useMemo(() => {
    const map = new Map<string, { sourceId: string; coverUrl: string }>()
    for (const alt of alternateSources) {
      const url = sanitizeImageUrl(alt.coverUrl)
      if (url && !map.has(url)) {
        map.set(url, { sourceId: alt.sourceId, coverUrl: url })
      }
    }
    return Array.from(map.values())
  }, [alternateSources])

  const previewSrc = useMemo(() => {
    if (uploadedCoverKey) return api.cover(uploadedCoverKey)
    if (coverUrl === '') return null
    if (coverUrl) return sanitizeImageUrl(coverUrl)
    if (item.coverKey) return api.cover(item.coverKey)
    return null
  }, [uploadedCoverKey, coverUrl, item.coverKey])

  const handleUploadCover = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const validExtensions = /\.(jpe?g|png|webp|gif|bmp)$/i
    if (!file.type.startsWith('image/') && !validExtensions.test(file.name)) {
      toast.error(t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB'))
      if (fileInputRef.current) fileInputRef.current.value = ''
      return
    }
    if (file.size > 5 * 1024 * 1024) {
      toast.error(t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB'))
      if (fileInputRef.current) fileInputRef.current.value = ''
      return
    }
    setUploadingCover(true)
    try {
      const res = await api.uploadCover(file)
      setUploadedCoverKey(res.coverKey)
      setCoverUrl(null) // clear external text url since we now have uploaded key
      toast.success(t('shelf.coverUploadSuccess', '封面上传成功'))
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.uploadCoverFailed', '上传封面失败'))
    } finally {
      setUploadingCover(false)
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  const handleSave = async (e: FormEvent) => {
    e.preventDefault()
    const trimmedName = name.trim()
    if (!trimmedName) {
      setError(t('shelf.bookTitleEmptyError', '书名不能为空'))
      return
    }

    setSaving(true)
    setError('')
    try {
      // 不要把本服务自己的封面接口地址当"外部封面地址"回写。
      // 之前 coverUrl 为空时会回退到 api.cover(coverKey)，于是存回 `/api/covers/<自己的 key>`，
      // 形成自引用。封面本来就由 coverKey 表达，这里只提交真实外部 URL。
      // 三种情形必须区分开（服务端语义：缺省=保留，空串=清除）：
      //   ① 用户没动过封面（coverUrl === null）⇒ 提交 undefined，服务端保留原值。
      //      原实现这里区分不开，于是「只改书名点保存」会把 cover_url 抹成 NULL。
      //   ② 用户点了「清除封面」（coverUrl === ''）⇒ 必须显式提交空串，否则清除不掉
      //      （空串会被下面的 externalCover 折成 undefined，看起来像「没动过」）。
      //   ③ 用户填了外部地址 ⇒ 提交该地址；若它是本服务自己的 /api/covers/<key>（自引用），
      //      则不提交 —— 封面本来就由 coverKey 表达。
      const externalCover = coverUrl && !coverUrl.startsWith('/api/covers/') ? coverUrl : undefined
      const coverUrlField = uploadedCoverKey ? undefined : coverUrl === null ? undefined : coverUrl === '' ? '' : externalCover
      const coverKeyField = uploadedCoverKey || (coverUrl === '' ? '' : undefined)
      const updated = await api.updateBookshelfInfo({
        sourceId: item.sourceId,
        bookUrl: item.bookUrl,
        name: trimmedName,
        author: author.trim() || undefined,
        coverUrl: coverUrlField,
        coverKey: coverKeyField,
        groupName: groupName || undefined,
        alternateSources,
        // 书籍变量里的 `custom`（Legado 的 `putCustomVariable`）：有声书用它切换朗读者/音色。
        // 始终提交当前值 —— "清空输入框"本身就是一个有意义的操作（下次用默认音色）。
        customVariable,
      })
      toast.success(t('shelf.bookInfoUpdated', '《{{name}}》信息已更新', { name: updated.name }))
      onSaved(updated)
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.bookInfoUpdateFailed', '更新书籍信息失败'))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      zIndex={340}
      withCloseButton={false}
      padding="lg"
      aria-label={t('shelf.editBookWithTitle', '编辑书籍信息: {{name}}', { name: item.name })}
    >
      <form onSubmit={handleSave}>
        <Stack gap="md">
          <Group justify="space-between" align="flex-start" pb="xs" style={{ borderBottom: '1px solid var(--line)' }}>
            <Stack gap={2}>
              <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
                {t('shelf.bookDetail', '书籍信息')}
              </Text>
              <Text fw={700} size="lg">{t('shelf.editBookInfo', '编辑书籍信息')}</Text>
            </Stack>
            <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
              <Icon name="close" size={16} />
            </ActionIcon>
          </Group>

          <ScrollArea.Autosize mah="68vh" offsetScrollbars>
            <Stack gap="md" pr={4}>
              {/* Online Search Completion */}
              <Paper p="sm" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
                <Stack gap="xs">
                  <Group justify="space-between" align="center" wrap="wrap" gap="xs">
                    <Button
                      size="xs"
                      variant={searchOpen ? 'light' : 'default'}
                      leftSection={<Icon name="search" size={14} />}
                      rightSection={
                        item.sourceId === 'loc_book' && (!item.author || candidateCovers.length === 0) ? (
                          <Badge size="xs" variant="filled" color="gold">{t('common.recommended', '推荐')}</Badge>
                        ) : undefined
                      }
                      onClick={() => {
                        const next = !searchOpen
                        setSearchOpen(next)
                        if (next && searchResults.length === 0 && !searching) {
                          handleStartSearch(searchKeyword || name)
                        }
                      }}
                    >
                      {searchOpen ? t('shelf.collapseMetaSearch', '收起联网搜索补全') : t('shelf.expandMetaSearch', '联网搜索补全信息')}
                    </Button>
                    {searchOpen && searching && (
                      <Group gap={6}>
                        <Loader size={12} />
                        <Text size="xs" c="dimmed">{t('shelf.searchingSources', '检索书源中...')}</Text>
                      </Group>
                    )}
                  </Group>

                  <Collapse in={searchOpen}>
                    <Stack gap="xs" pt="xs">
                      <Group gap="xs" wrap="nowrap">
                        <TextInput
                          size="xs"
                          style={{ flex: 1 }}
                          leftSection={<Icon name="search" size={14} />}
                          placeholder={t('shelf.metaSearchPlaceholder', '输入小说名称搜索网络书源...')}
                          value={searchKeyword}
                          onChange={e => setSearchKeyword(e.target.value)}
                          onKeyDown={e => {
                            if (e.key === 'Enter') {
                              e.preventDefault()
                              handleStartSearch()
                            }
                          }}
                        />
                        {searching ? (
                          <Button size="xs" variant="light" color="red" onClick={stopSearch}>
                            {t('common.pause', '停止')}
                          </Button>
                        ) : (
                          <Button size="xs" leftSection={<Icon name="search" size={14} />} onClick={() => handleStartSearch()}>
                            {t('common.search', '搜索')}
                          </Button>
                        )}
                      </Group>

                      {searchProgress && (
                        <Stack gap={4}>
                          <Group justify="space-between">
                            <Text size="xs" c="dimmed">
                              {t('shelf.metaSearchProgress', '已检索 {{completed}}/{{total}} 个书源{{matchedText}}', {
                                completed: searchProgress.completedSources,
                                total: searchProgress.totalSources,
                                matchedText: searchProgress.matchedSources > 0 ? t('shelf.metaSearchMatched', ' · 命中 {{count}} 个', { count: searchProgress.matchedSources }) : '',
                              })}
                            </Text>
                            <Badge size="xs" variant="light">
                              {t('shelf.metaSearchResultsCount', '共 {{count}} 条结果', { count: searchResults.length })}
                            </Badge>
                          </Group>
                          <Progress
                            size="xs"
                            radius="xl"
                            value={searchProgress.totalSources > 0 ? (searchProgress.completedSources / searchProgress.totalSources) * 100 : 0}
                          />
                        </Stack>
                      )}

                      {searchError && (
                        <Alert color="red" variant="light" p="xs">
                          <Text size="xs">{searchError}</Text>
                        </Alert>
                      )}

                      {searchResults.length > 0 ? (
                        <ScrollArea.Autosize mah={240} offsetScrollbars>
                          <Stack gap={6}>
                            {searchResults.map((cand, idx) => {
                              const candCover = sanitizeImageUrl(cand.coverUrl)
                              const isChosen = (coverUrl === cand.coverUrl) && (author === cand.author)
                              return (
                                <Paper
                                  key={`${cand.sourceId}_${cand.bookUrl}_${idx}`}
                                  p="xs"
                                  withBorder
                                  radius="sm"
                                  style={{ borderColor: isChosen ? 'var(--accent)' : undefined }}
                                >
                                  <Group align="flex-start" wrap="nowrap" gap="xs">
                                    <Box w={42} className="legado-cover-frame">
                                      <BookCover coverUrl={candCover ?? undefined} name={cand.name} />
                                    </Box>
                                    <Stack gap={2} style={{ flex: 1, minWidth: 0 }}>
                                      <Group gap={6} wrap="nowrap">
                                        <Text size="xs" fw={600} truncate style={{ flex: 1, minWidth: 0 }}>{cand.name}</Text>
                                        <Badge size="xs" variant="light" color="gray">{cand.sourceId}</Badge>
                                      </Group>
                                      <Text size="xs" c="dimmed" truncate>
                                        {t('shelf.author', '作者')}：{cand.author || t('common.unknownAuthor', '未知作者')}
                                      </Text>
                                      {cand.intro && (
                                        <Text size="xs" c="dimmed" lineClamp={1}>{cand.intro}</Text>
                                      )}
                                    </Stack>
                                    <Button
                                      size="compact-xs"
                                      variant={isChosen ? 'filled' : 'light'}
                                      leftSection={<Icon name={isChosen ? 'check' : 'plus'} size={12} />}
                                      onClick={() => handleApplyCandidate(cand)}
                                      title={t('shelf.applyCandidateTitle', '采用此候选的封面和作者')}
                                    >
                                      {isChosen ? t('shelf.appliedCandidate', '已选用') : t('shelf.applyCandidate', '选用')}
                                    </Button>
                                  </Group>
                                </Paper>
                              )
                            })}
                          </Stack>
                        </ScrollArea.Autosize>
                      ) : !searching && searchProgress?.completedSources ? (
                        <Text size="xs" c="dimmed" ta="center" py="xs">
                          {t('shelf.metaSearchEmpty', '未检索到匹配结果，可尝试修改搜索关键词后再次检索')}
                        </Text>
                      ) : null}
                    </Stack>
                  </Collapse>
                </Stack>
              </Paper>

              {/* Cover Preview & Options */}
              <Group align="flex-start" wrap="wrap" gap="md">
                <Stack gap={6} align="center" w={104}>
                  <Box w={96} className="legado-cover-frame">
                    {previewSrc && sanitizeImageUrl(previewSrc) ? (
                      <img src={sanitizeImageUrl(previewSrc)!} alt={t('shelf.coverPreview', '封面预览')} referrerPolicy="no-referrer" />
                    ) : (
                      <div className="legado-cover-fallback">
                        <span>{name.trim().slice(0, 1) || t('common.bookChar', '书')}</span>
                      </div>
                    )}
                  </Box>
                  {(uploadedCoverKey || (coverUrl !== '' && (item.coverKey || coverUrl))) && (
                    <Button
                      size="compact-xs"
                      variant="subtle"
                      color="red"
                      onClick={() => {
                        setUploadedCoverKey(null)
                        setCoverUrl('')
                      }}
                    >
                      {t('shelf.clearCover', '清除封面')}
                    </Button>
                  )}
                  {(uploadedCoverKey !== null || coverUrl === '') && (
                    <Button
                      size="compact-xs"
                      variant="subtle"
                      onClick={() => {
                        setUploadedCoverKey(null)
                        setCoverUrl(null)
                      }}
                    >
                      {t('shelf.restoreCover', '恢复原封面')}
                    </Button>
                  )}
                </Stack>

                <Stack gap="xs" style={{ flex: 1, minWidth: 220 }}>
                  <Group gap="xs" wrap="wrap">
                    <input
                      type="file"
                      ref={fileInputRef}
                      style={{ display: 'none' }}
                      accept="image/jpeg,image/png,image/webp,image/gif,image/bmp,.jpg,.jpeg,.png,.webp,.gif,.bmp"
                      onChange={handleUploadCover}
                    />
                    <Button
                      size="xs"
                      variant="default"
                      loading={uploadingCover}
                      leftSection={<Icon name="upload" size={14} />}
                      onClick={() => fileInputRef.current?.click()}
                    >
                      {uploadingCover ? t('shelf.uploadingCover', '正在上传封面...') : t('shelf.uploadCover', '上传本地封面')}
                    </Button>
                    <Text size="xs" c="dimmed">{t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB')}</Text>
                  </Group>

                  <TextInput
                    size="xs"
                    label={t('shelf.coverUrl', '封面图片 URL')}
                    description={t('shelf.coverUrlHint', '可粘贴图片网络地址，保存时将自动拉取并缓存到服务器')}
                    leftSection={<Icon name="image" size={14} />}
                    placeholder="https://example.com/cover.jpg"
                    value={coverUrl === null ? '' : coverUrl}
                    onChange={e => {
                      setUploadedCoverKey(null)
                      setCoverUrl(e.target.value)
                    }}
                  />

                  {candidateCovers.length > 0 && (
                    <Stack gap={6}>
                      <Text size="xs" fw={600}>
                        {t('shelf.chooseCoverFromCandidates', '从备选书源选择封面 ({{count}})：', { count: candidateCovers.length })}
                      </Text>
                      <Group gap="xs" wrap="wrap">
                        {candidateCovers.map(c => {
                          const isSelected = !uploadedCoverKey && coverUrl === c.coverUrl
                          return (
                            <Paper
                              key={c.coverUrl}
                              component="button"
                              type="button"
                              p={4}
                              withBorder
                              radius="sm"
                              w={64}
                              onClick={() => {
                                setUploadedCoverKey(null)
                                setCoverUrl(c.coverUrl)
                              }}
                              title={t('shelf.useSourceCoverTitle', '使用来自【{{source}}】的封面', { source: c.sourceId })}
                              style={{ borderColor: isSelected ? 'var(--accent)' : undefined }}
                            >
                              <Box w="100%" className="legado-cover-frame">
                                <BookCover coverUrl={c.coverUrl} name={c.sourceId} />
                              </Box>
                              <Text size="10px" c="dimmed" truncate mt={2} ta="center">{c.sourceId}</Text>
                            </Paper>
                          )
                        })}
                      </Group>
                    </Stack>
                  )}
                </Stack>
              </Group>

              <Divider />

              <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
                <TextInput
                  label={t('shelf.bookTitle', '书名')}
                  required
                  value={name}
                  onChange={e => setName(e.target.value)}
                  placeholder={t('shelf.bookTitleRequired', '请输入书名')}
                />
                <TextInput
                  label={t('shelf.author', '作者')}
                  value={author}
                  onChange={e => setAuthor(e.target.value)}
                  placeholder={t('shelf.authorOptional', '作者（可选）')}
                />
                <Select
                  label={t('shelf.group', '所属分组')}
                  comboboxProps={{ zIndex: 380 }}
                  value={groupName || ''}
                  onChange={val => setGroupName(val || undefined)}
                  data={[
                    { value: '', label: `(${t('search.scopeUngrouped', '未分组')})` },
                    ...groups.map(g => ({ value: g.name, label: g.name })),
                  ]}
                />
                <TextInput
                  label={t('shelf.bookVariable', '书籍变量')}
                  description={t('shelf.bookVariableHint', '书源规则通过 book.getVariable("custom") 读取本值；听书填书籍详情里显示的可用音色编号即可切换朗读者，留空用默认音色')}
                  value={customVariable}
                  onChange={e => setCustomVariable(e.target.value)}
                  placeholder={t('shelf.bookVariablePlaceholder', '如音色编号：3')}
                />
              </SimpleGrid>

              {error && (
                <Alert color="red" variant="light" p="xs">
                  <Text size="xs">{error}</Text>
                </Alert>
              )}
            </Stack>
          </ScrollArea.Autosize>

          <Group justify="flex-end" gap="xs" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
            <Button variant="default" onClick={onClose} disabled={saving}>
              {t('common.cancel', '取消')}
            </Button>
            <Button type="submit" loading={saving}>
              {saving ? t('common.saving', '保存中...') : t('common.saveChanges', '保存修改')}
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}

function ManageActionRow({
  icon,
  title,
  description,
  danger,
  busy,
  disabled,
  onClick,
}: {
  icon: React.ComponentProps<typeof Icon>['name']
  title: string
  description: string
  danger?: boolean
  busy?: boolean
  disabled?: boolean
  onClick: () => void
}) {
  return (
    <Paper
      component="button"
      type="button"
      p="xs"
      withBorder
      radius="md"
      disabled={disabled || busy}
      onClick={onClick}
      className="legado-interactive-card"
      style={{
        width: '100%',
        textAlign: 'left',
        borderColor: danger ? 'color-mix(in srgb, var(--danger) 35%, var(--line))' : undefined,
      }}
    >
      <Group justify="space-between" wrap="nowrap" gap="sm">
        <Group gap="sm" wrap="nowrap" style={{ flex: 1, minWidth: 0 }}>
          <ThemeIcon size={34} radius="md" variant="light" color={danger ? 'red' : 'brand'}>
            <Icon name={icon} size={16} />
          </ThemeIcon>
          <Stack gap={1} style={{ flex: 1, minWidth: 0 }}>
            <Text size="sm" fw={600} c={danger ? 'red' : undefined} truncate>{title}</Text>
            <Text size="xs" c="dimmed" lineClamp={2}>{description}</Text>
          </Stack>
        </Group>
        <Box c={danger ? 'red' : 'dimmed'}>
          {busy ? <Loader size={14} /> : <Icon name="chevronRight" size={16} />}
        </Box>
      </Group>
    </Paper>
  )
}

function BookManageModal({
  item,
  groups,
  onClose,
  onOpenDetail,
  onExport,
  onSwitchSource,
  onCache,
  onCancelCache,
  onSetCanUpdate,
  updateSettingBusy,
  onToggleCompleted,
  onUpdateInfo,
  onClearCache,
  onRemove,
}: {
  item: BookshelfItem
  groups: BookGroup[]
  onClose: () => void
  onOpenDetail: () => void
  onExport: () => void
  onSwitchSource: () => void
  onCache: (chapterConcurrency?: number) => Promise<boolean>
  onCancelCache: () => void
  onSetCanUpdate: (canUpdate: boolean) => Promise<void>
  updateSettingBusy: boolean
  onToggleCompleted: () => void
  onUpdateInfo: (updated: BookshelfItem) => void
  onClearCache: () => void
  onRemove: () => void
}) {
  const { t } = useTranslation()
  const [editingInfo, setEditingInfo] = useState(false)
  const [recleaning, setRecleaning] = useState(false)
  const [reparsing, setReparsing] = useState(false)
  const [cacheConcurrencyOpen, setCacheConcurrencyOpen] = useState(false)
  const [cacheStarting, setCacheStarting] = useState(false)
  const [ignoringEmptyChapter, setIgnoringEmptyChapter] = useState(false)
  const isQueued = item.cacheState === 'pending'
  const isCaching = item.cacheState === 'caching'
  const isReady = item.cacheState === 'ready'
  const isFailed = item.cacheState === 'failed'
  const hasEmptyContentFailure = isFailed && Boolean(item.cacheError?.includes('正文规则未提取到内容'))
  const percent = Math.min(100, Math.round((item.cachedChapters / Math.max(1, item.totalChapters || 1)) * 100))

  if (editingInfo) {
    return (
      <BookInfoEditModal
        item={item}
        groups={groups}
        onSaved={updated => {
          onUpdateInfo(updated)
          setEditingInfo(false)
        }}
        onClose={() => setEditingInfo(false)}
      />
    )
  }

  const statusText = item.isReadFinished
    ? t('shelf.statusRead', '已读')
    : item.isReading
      ? t('shelf.readingProgress', '读至：{{chapter}}', { chapter: t('shelf.chapterAt', '第 {{count}} 章', { count: (item.chapterIndex ?? 0) + 1 }) })
      : item.isUnread
        ? t('shelf.statusUnread', '未读')
        : item.completed
          ? t('shelf.completed', '已读完')
          : item.chapterIndex === undefined
            ? t('shelf.justAdded', '刚加入书架')
            : t('shelf.readingProgress', '读至：{{chapter}}', { chapter: t('shelf.chapterAt', '第 {{count}} 章', { count: item.chapterIndex + 1 }) })

  return (
    <>
      <Modal
        opened
        onClose={onClose}
        size="md"
        zIndex={310}
        withCloseButton={false}
        closeOnEscape={!editingInfo && !cacheConcurrencyOpen}
        closeOnClickOutside={!editingInfo && !cacheConcurrencyOpen}
        trapFocus={!editingInfo && !cacheConcurrencyOpen}
        padding="lg"
        aria-label={t('shelf.bookManageWithTitle', '书籍管理: {{name}}', { name: item.name })}
      >
        <Stack gap="md">
          <Group justify="space-between" align="flex-start" wrap="nowrap" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
            <Group align="flex-start" wrap="nowrap" gap="sm" style={{ flex: 1, minWidth: 0 }}>
              <Box w={56} className="legado-cover-frame">
                <BookCover coverKey={item.coverKey} coverUrl={item.coverUrl} name={item.name} />
              </Box>
              <Stack gap={2} style={{ flex: 1, minWidth: 0 }}>
                <Text fw={700} size="md" truncate>{item.name}</Text>
                <Text size="xs" c="dimmed" truncate>{item.author || t('common.unknownAuthor', '未知作者')}</Text>
                <Badge size="xs" variant="light" color="brand" w="fit-content">{statusText}</Badge>
                {item.updateError && (
                  <Text size="xs" c="red">{t('shelf.lastRefreshFailed', '上次目录刷新失败，已保留原目录')}</Text>
                )}
              </Stack>
            </Group>
            <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
              <Icon name="close" size={16} />
            </ActionIcon>
          </Group>

          <ScrollArea.Autosize mah="64vh" offsetScrollbars>
            <Stack gap="xs" pr={4}>
              <Paper p="xs" withBorder radius="md">
                <Group justify="space-between" wrap="nowrap" gap="sm">
                  <Group gap="sm" wrap="nowrap" style={{ minWidth: 0 }}>
                    <ThemeIcon size={34} radius="md" variant="light" color="brand">
                      <Icon name="bookmark" size={16} />
                    </ThemeIcon>
                    <Stack gap={1}>
                      <Text size="sm" fw={600}>{t('shelf.group', '所属分组')}</Text>
                      <Text size="xs" c="dimmed">
                        {t('shelf.currentGroup', '当前：{{group}}', { group: item.groupName || t('search.scopeUngrouped', '未分组') })}
                      </Text>
                    </Stack>
                  </Group>
                  <Select
                    size="xs"
                    w={135}
                    comboboxProps={{ zIndex: 380 }}
                    aria-label={t('shelf.modifyGroup', '修改所属分组')}
                    value={item.groupName || ''}
                    onChange={async val => {
                      const newGroup = val || null
                      try {
                        const updated = await api.updateBookGroup(item.sourceId, item.bookUrl, newGroup)
                        onUpdateInfo(updated)
                        toast.success(newGroup ? t('shelf.movedToGroup', '已移入「{{group}}」分组', { group: newGroup }) : t('shelf.movedToUngrouped', '已移入「未分组」'))
                      } catch (err) {
                        toast.error(err instanceof Error ? err.message : t('shelf.updateGroupFailed', '更新分组失败'))
                      }
                    }}
                    data={[
                      { value: '', label: t('search.scopeUngrouped', '未分组') },
                      ...groups.map(g => ({ value: g.name, label: g.name })),
                    ]}
                  />
                </Group>
              </Paper>

              {!isLocalBook(item) && (
                <ManageActionRow
                  icon={item.canUpdate === false ? 'refresh' : 'stop'}
                  title={item.canUpdate === false ? t('shelf.resumeUpdates', '恢复目录更新') : t('shelf.pauseUpdates', '停止目录更新')}
                  description={item.canUpdate === false
                    ? t('shelf.resumeUpdatesDesc', '允许这本书重新参与书架目录刷新')
                    : t('shelf.pauseUpdatesDesc', '刷新书架时跳过这本书，阅读进度和缓存不受影响')}
                  busy={updateSettingBusy}
                  onClick={() => void onSetCanUpdate(!item.canUpdate)}
                />
              )}

              <ManageActionRow
                icon="file"
                title={t('shelf.viewDetails', '查看书籍详情')}
                description="阅读进度、缓存状态、简介与更新情况"
                onClick={() => { onClose(); onOpenDetail() }}
              />

              <ManageActionRow
                icon="edit"
                title={t('shelf.editBookInfo', '编辑书籍信息')}
                description={t('shelf.editBookInfoDesc', '修改书名、作者或更换封面')}
                onClick={() => setEditingInfo(true)}
              />

              <ManageActionRow
                icon="download"
                title="导出与推送到 Kindle"
                description="导出 TXT / EPUB，EPUB 可直接推送到已配对设备"
                onClick={onExport}
              />

              {!isLocalBook(item) && (
                <ManageActionRow
                  icon="sliders"
                  title={t('source.switchSourceTitle', '切换书源')}
                  description={item.alternateSources?.length ? t('shelf.switchSourceDescWithCount', '已有 {{count}} 个备选书源，可全网检索', { count: item.alternateSources.length }) : t('shelf.switchSourceDesc', '在其他书源中搜索匹配并无缝替换')}
                  onClick={() => { onClose(); onSwitchSource() }}
                />
              )}

              {!isLocalBook(item) && (
                isCaching || isQueued ? (
                  <Paper p="sm" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
                    <Stack gap="xs">
                      <Group justify="space-between" wrap="nowrap">
                        <Group gap="sm" wrap="nowrap">
                          <ThemeIcon size={32} radius="md" variant="light" color="brand">
                            <Icon name="cloudDownload" size={16} />
                          </ThemeIcon>
                          <Stack gap={1}>
                            <Text size="sm" fw={600}>
                              {isQueued ? t('shelf.cachePending', '缓存排队中') : t('shelf.cachingAll', '正在离线缓存全本')}
                            </Text>
                            <Text size="xs" c="dimmed">
                              {percent}% ({item.cachedChapters} / {item.totalChapters || '?'}) {t('reader.cacheCustomUnit', '章')}
                            </Text>
                          </Stack>
                        </Group>
                        <Button size="compact-xs" variant="light" color="red" onClick={onCancelCache}>
                          {t('shelf.cancelCacheLink', '取消缓存')}
                        </Button>
                      </Group>
                      <Progress value={percent} animated size="sm" radius="xl" />
                    </Stack>
                  </Paper>
                ) : (
                  <ManageActionRow
                    icon="cloudDownload"
                    title={isReady ? t('shelf.recacheOrVerify', '重新缓存 / 校验全本') : isFailed ? t('shelf.retryCache', '重试离线缓存') : t('shelf.cacheAllTitle', '离线缓存全本')}
                    description={isReady ? t('shelf.cacheAllDescReady', '已离线缓存 {{count}} 章', { count: item.cachedChapters }) : isFailed ? (item.cacheError || t('shelf.cacheAllDescFailed', '部分章节未缓存，点击重试')) : t('shelf.cacheAllDescIdle', '预先下载全书正文以供离线阅读')}
                    onClick={() => {
                      if ((item.bookKind ?? 'novel') === 'novel') setCacheConcurrencyOpen(true)
                      else void onCache()
                    }}
                  />
                )
              )}

              {!isLocalBook(item) && hasEmptyContentFailure && (
                <ManageActionRow
                  icon="volume2"
                  title={ignoringEmptyChapter
                    ? t('shelf.ignoreEmptyChapterBusy', '正在标记并重新校验...')
                    : t('shelf.ignoreEmptyChapter', '将失败空章标记为空卷')}
                  description={t(
                    'shelf.ignoreEmptyChapterDesc',
                    '仅用于书源页面明确显示 0 字的卷分隔页；普通章节不会被自动忽略',
                  )}
                  busy={ignoringEmptyChapter}
                  onClick={async () => {
                    if (!window.confirm(t(
                      'shelf.ignoreEmptyChapterConfirm',
                      '已确认该章在书源页面中确实没有正文吗？确认后会将该失败章标记为空卷标题，不再抓取正文；EPUB 中保留为卷标题，Kindle 上架中不作为可读章节，并重新校验全书。',
                    ))) return
                    setIgnoringEmptyChapter(true)
                    try {
                      const result = await api.ignoreFailedEmptyChapter(item.sourceId, item.bookUrl)
                      toast.success(t(
                        'shelf.ignoreEmptyChapterSuccess',
                        '已将「{{title}}」标记为空卷，正在重新校验全书缓存',
                        { title: result.title },
                      ))
                      onUpdateInfo({ ...item, cacheState: 'caching', cacheError: undefined })
                      onClose()
                    } catch (err) {
                      toast.error(err instanceof Error ? err.message : t(
                        'shelf.ignoreEmptyChapterFailed',
                        '标记空卷失败',
                      ))
                    } finally {
                      setIgnoringEmptyChapter(false)
                    }
                  }}
                />
              )}

              <ManageActionRow
                icon="sliders"
                title={recleaning ? t('shelf.recleaningDesc', '正在重新清洗正文...') : t('shelf.recleanRules', '重新应用净化规则')}
                description={t('shelf.recleanRulesDesc', '基于原文副本重新运行当前启用的替换规则')}
                busy={recleaning}
                onClick={async () => {
                  setRecleaning(true)
                  try {
                    const res = await api.recleanBookCache(item.sourceId, item.bookUrl)
                    if (res.recleanedChapters > 0) {
                      toast.success(t('shelf.recleanSuccess', '《{{name}}》重新清洗完成，共处理 {{count}} 章', { name: item.name, count: res.recleanedChapters }))
                    } else {
                      toast.info(t('shelf.recleanNoChapters', '《{{name}}》暂无已缓存章节', { name: item.name }))
                    }
                  } catch (err) {
                    toast.error(err instanceof Error ? err.message : t('shelf.recleanFailed', '重新清洗失败'))
                  } finally {
                    setRecleaning(false)
                  }
                }}
              />

              {isLocalBook(item) && (
                <ManageActionRow
                  icon="refresh"
                  title={reparsing ? t('shelf.reparsingDesc', '正在重新解析本地文件...') : t('shelf.reparseLocalRules', '重新解析本地文件')}
                  description={t('shelf.reparseLocalRulesDesc', '按留存的 TXT / EPUB 原文件重建目录与正文，阅读进度保留')}
                  busy={reparsing}
                  onClick={async () => {
                    setReparsing(true)
                    try {
                      const res = await api.reparseLocalBooks({ sourceId: item.sourceId, bookUrl: item.bookUrl })
                      if (res.reparsed > 0) {
                        toast.success(t('shelf.reparseLocalSuccess', '《{{name}}》已重新解析，共 {{count}} 章', { name: item.name, count: res.chapters }))
                        onUpdateInfo(item)
                      } else {
                        toast.info(res.items[0]?.error ?? t('shelf.reparseLocalSkipped', '《{{name}}》无需重新解析', { name: item.name }))
                      }
                    } catch (err) {
                      toast.error(err instanceof Error ? err.message : t('shelf.reparseLocalFailed', '重新解析失败'))
                    } finally {
                      setReparsing(false)
                    }
                  }}
                />
              )}

              <ManageActionRow
                icon="check"
                title={item.completed ? t('shelf.markAsReading', '恢复为正在阅读') : t('shelf.markAsCompleted', '标记为已读完')}
                description={item.completed ? t('shelf.markAsReadingDesc', '状态恢复为正在阅读') : t('shelf.markAsCompletedDesc', '状态标记为已读完')}
                onClick={() => { onClose(); onToggleCompleted() }}
              />

              {!isLocalBook(item) && (
                <ManageActionRow
                  icon="trash"
                  danger
                  title={t('shelf.clearCache', '清除缓存')}
                  description={t('shelf.clearCacheDesc', '清除本书已下载的图片、音频与正文缓存（含本机离线）')}
                  onClick={() => onClearCache()}
                />
              )}

              <ManageActionRow
                icon="close"
                danger
                title={t('shelf.removeFromShelf', '移出书架')}
                description={t('shelf.removeFromShelfDesc', '清除阅读进度与离线缓存')}
                onClick={() => { onClose(); onRemove() }}
              />
            </Stack>
          </ScrollArea.Autosize>
        </Stack>
      </Modal>
      {cacheConcurrencyOpen && (
        <CacheConcurrencyDialog
          bookName={item.name}
          busy={cacheStarting}
          onCancel={() => setCacheConcurrencyOpen(false)}
          onConfirm={chapterConcurrency => {
            setCacheStarting(true)
            void onCache(chapterConcurrency)
              .then(success => {
                if (success) setCacheConcurrencyOpen(false)
              })
              .finally(() => setCacheStarting(false))
          }}
        />
      )}
    </>
  )
}

function ClearCacheScopeModal({
  item,
  busy,
  busyScope,
  onPick,
  onClose,
}: {
  item: BookshelfItem
  theme: ReaderTheme
  busy: boolean
  busyScope?: ClearCacheScope | null
  onPick: (scope: ClearCacheScope) => void
  onClose: () => void
}) {
  const { t } = useTranslation()

  return (
    <Modal
      opened
      onClose={busy ? () => undefined : onClose}
      size="md"
      zIndex={330}
      withCloseButton={false}
      closeOnEscape={!busy}
      closeOnClickOutside={!busy}
      padding="lg"
      aria-label={t('shelf.clearCacheTitle', '清除缓存')}
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" wrap="nowrap" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
          <Group align="flex-start" wrap="nowrap" gap="sm" style={{ flex: 1, minWidth: 0 }}>
            <Box w={52} className="legado-cover-frame">
              <BookCover coverKey={item.coverKey} coverUrl={item.coverUrl} name={item.name} />
            </Box>
            <Stack gap={2} style={{ flex: 1, minWidth: 0 }}>
              <Text fw={700} size="md" truncate>{item.name}</Text>
              <Text size="xs" fw={600} c="red">{t('shelf.clearCacheTitle', '清除缓存')}</Text>
              <Text size="xs" c="dimmed">
                {t('shelf.clearCacheHint', '将清除《{{name}}》已下载的缓存；阅读进度、书架记录与封面不受影响，请选择清除范围。', { name: item.name })}
              </Text>
            </Stack>
          </Group>
          <ActionIcon variant="subtle" color="gray" disabled={busy} onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" size={16} />
          </ActionIcon>
        </Group>

        <Stack gap="xs">
          <ManageActionRow
            icon="cloudDownload"
            danger
            disabled={busy}
            busy={busyScope === 'server'}
            title={t('shelf.clearCacheServer', '清除服务器缓存')}
            description={isLocalBook(item) ? t('shelf.clearCacheServerLocalDesc', '本地书正文由原文件解析而来，清除缓存不会删除原文件') : t('shelf.clearCacheServerDesc', '清掉服务端已下载的正文与插图，下次阅读会重新获取')}
            onClick={() => onPick('server')}
          />
          <ManageActionRow
            icon="download"
            danger
            disabled={busy}
            busy={busyScope === 'browser'}
            title={t('shelf.clearCacheBrowser', '清除浏览器缓存')}
            description={t('shelf.clearCacheBrowserDesc', '只清本机已下载的离线正文，不影响服务端')}
            onClick={() => onPick('browser')}
          />
          <ManageActionRow
            icon="trash"
            danger
            disabled={busy}
            busy={busyScope === 'both'}
            title={t('shelf.clearCacheBoth', '清理服务器和浏览器缓存')}
            description={t('shelf.clearCacheBothDesc', '一次清干净：服务端与本机一起清')}
            onClick={() => onPick('both')}
          />
          <ManageActionRow
            icon="close"
            disabled={busy}
            title={t('shelf.clearCacheCancel', '取消')}
            description={t('shelf.clearCacheCancelDesc', '不做任何清理，返回书籍管理')}
            onClick={onClose}
          />
        </Stack>
      </Stack>
    </Modal>
  )
}

function GroupManageModal({
  groups,
  onClose,
  onGroupsChanged,
}: {
  groups: BookGroup[]
  onClose: () => void
  onGroupsChanged: () => Promise<void>
}) {
  const { t } = useTranslation()
  const [newGroupName, setNewGroupName] = useState('')
  const [adding, setAdding] = useState(false)
  const [editingId, setEditingId] = useState<number | null>(null)
  const [editingName, setEditingName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const handleAddGroup = async (e: FormEvent) => {
    e.preventDefault()
    const trimmed = newGroupName.trim()
    if (!trimmed) return
    setAdding(true)
    setError('')
    try {
      await api.createBookGroup(trimmed)
      setNewGroupName('')
      await onGroupsChanged()
      toast.success(t('shelf.groupCreated', '分组「{{name}}」创建成功', { name: trimmed }))
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.createGroupFailed', '创建分组失败'))
    } finally {
      setAdding(false)
    }
  }

  const handleRename = async (group: BookGroup) => {
    const trimmed = editingName.trim()
    if (!trimmed || trimmed === group.name) {
      setEditingId(null)
      return
    }
    setBusy(true)
    setError('')
    try {
      await api.renameBookGroup(group.name, trimmed)
      setEditingId(null)
      await onGroupsChanged()
      toast.success(t('shelf.groupRenamed', '分组已重命名为「{{name}}」', { name: trimmed }))
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.renameGroupFailed', '重命名失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleDelete = async (group: BookGroup) => {
    const confirmMsg = group.bookCount > 0
      ? t('shelf.deleteGroupConfirmWithCount', '确定删除分组「{{name}}」吗？组内 {{count}} 本书籍将自动归入“未分组”，书籍不会被删除。', { name: group.name, count: group.bookCount })
      : t('shelf.deleteGroupConfirm', '确定删除分组「{{name}}」吗？', { name: group.name })
    if (!confirm(confirmMsg)) return
    setBusy(true)
    setError('')
    try {
      await api.deleteBookGroup(group.name)
      await onGroupsChanged()
      toast.info(t('shelf.groupDeleted', '已删除分组「{{name}}」', { name: group.name }))
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.deleteGroupFailed', '删除失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleMove = async (index: number, direction: 'up' | 'down') => {
    const targetIndex = direction === 'up' ? index - 1 : index + 1
    if (targetIndex < 0 || targetIndex >= groups.length) return
    const reordered = [...groups]
    const temp = reordered[index]
    reordered[index] = reordered[targetIndex]
    reordered[targetIndex] = temp
    setBusy(true)
    try {
      await api.reorderBookGroups(reordered.map(g => g.name))
      await onGroupsChanged()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.reorderGroupFailed', '调整排序失败'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      opened
      onClose={onClose}
      size="md"
      zIndex={330}
      withCloseButton={false}
      padding="lg"
      aria-label={t('shelf.manageGroups', '管理书架分组')}
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" pb="xs" style={{ borderBottom: '1px solid var(--line)' }}>
          <Stack gap={2}>
            <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
              {t('shelf.groupManageKicker', '书架分类')}
            </Text>
            <Text fw={700} size="lg">{t('shelf.groupManageTitle', '书架分组管理')}</Text>
          </Stack>
          <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" size={16} />
          </ActionIcon>
        </Group>

        <form onSubmit={handleAddGroup}>
          <Group gap="xs" wrap="nowrap">
            <TextInput
              style={{ flex: 1 }}
              value={newGroupName}
              onChange={e => setNewGroupName(e.target.value)}
              placeholder={t('shelf.groupNamePlaceholder', '输入新分组名称...')}
              maxLength={20}
              disabled={adding || busy}
            />
            <Button type="submit" loading={adding} disabled={!newGroupName.trim() || busy}>
              {adding ? t('shelf.creatingGroup', '创建中...') : t('shelf.createGroup', '新建分组')}
            </Button>
          </Group>
        </form>

        {error && (
          <Alert color="red" variant="light" p="xs">
            <Text size="xs">{error}</Text>
          </Alert>
        )}

        <ScrollArea.Autosize mah={320} offsetScrollbars>
          {groups.length === 0 ? (
            <Text size="sm" c="dimmed" ta="center" py="lg">
              {t('shelf.groupEmptyTip', '暂无自定义分组，创建后可自由归类书籍')}
            </Text>
          ) : (
            <Stack gap={6}>
              {groups.map((group, idx) => (
                <Paper key={group.id} p="xs" withBorder radius="md">
                  {editingId === group.id ? (
                    <Group gap="xs" wrap="nowrap">
                      <TextInput
                        size="xs"
                        style={{ flex: 1 }}
                        value={editingName}
                        onChange={e => setEditingName(e.target.value)}
                        autoFocus
                        maxLength={20}
                        onKeyDown={e => {
                          if (e.key === 'Enter') void handleRename(group)
                          if (e.key === 'Escape') setEditingId(null)
                        }}
                      />
                      <ActionIcon color="brand" variant="light" onClick={() => void handleRename(group)} disabled={busy} title={t('common.save', '保存')}>
                        <Icon name="check" size={14} />
                      </ActionIcon>
                      <ActionIcon color="gray" variant="subtle" onClick={() => setEditingId(null)} title={t('common.cancel', '取消')}>
                        <Icon name="close" size={14} />
                      </ActionIcon>
                    </Group>
                  ) : (
                    <Group justify="space-between" wrap="nowrap">
                      <Group gap="xs" wrap="nowrap" style={{ minWidth: 0 }}>
                        <Text size="sm" fw={600} truncate>{group.name}</Text>
                        <Badge size="xs" variant="light" color="gray">
                          {t('shelf.booksInGroup', '{{count}} 本', { count: group.bookCount })}
                        </Badge>
                      </Group>
                      <Group gap={4} wrap="nowrap">
                        <Tooltip label={t('shelf.moveUp', '上移')}>
                          <ActionIcon variant="subtle" color="gray" disabled={idx === 0 || busy} onClick={() => void handleMove(idx, 'up')}>
                            <Icon name="arrowUp" size={14} />
                          </ActionIcon>
                        </Tooltip>
                        <Tooltip label={t('shelf.moveDown', '下移')}>
                          <ActionIcon variant="subtle" color="gray" disabled={idx === groups.length - 1 || busy} onClick={() => void handleMove(idx, 'down')}>
                            <Icon name="arrowDown" size={14} />
                          </ActionIcon>
                        </Tooltip>
                        <Tooltip label={t('shelf.rename', '重命名')}>
                          <ActionIcon
                            variant="subtle"
                            color="gray"
                            onClick={() => {
                              setEditingId(group.id)
                              setEditingName(group.name)
                            }}
                          >
                            <Icon name="edit" size={14} />
                          </ActionIcon>
                        </Tooltip>
                        <Tooltip label={t('shelf.deleteGroup', '删除分组')}>
                          <ActionIcon variant="subtle" color="red" onClick={() => void handleDelete(group)}>
                            <Icon name="trash" size={14} />
                          </ActionIcon>
                        </Tooltip>
                      </Group>
                    </Group>
                  )}
                </Paper>
              ))}
            </Stack>
          )}
        </ScrollArea.Autosize>

        <Group justify="flex-end" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
          <Button onClick={onClose}>{t('common.ok', '完成')}</Button>
        </Group>
      </Stack>
    </Modal>
  )
}

function BatchMoveGroupModal({
  groups,
  selectedCount,
  onClose,
  onSelectGroup,
}: {
  groups: BookGroup[]
  selectedCount: number
  onClose: () => void
  onSelectGroup: (groupName: string | null) => Promise<void>
}) {
  const { t } = useTranslation()
  const [busy, setBusy] = useState(false)

  const handleSelect = async (groupName: string | null) => {
    setBusy(true)
    try {
      await onSelectGroup(groupName)
      onClose()
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      opened
      onClose={onClose}
      size="sm"
      zIndex={330}
      withCloseButton={false}
      padding="lg"
      aria-label={t('shelf.batchMoveToGroup', '移动书籍至分组')}
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" pb="xs" style={{ borderBottom: '1px solid var(--line)' }}>
          <Stack gap={2}>
            <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
              {t('shelf.batchKicker', '批量操作')}
            </Text>
            <Text fw={700} size="lg">{t('shelf.batchMoveToGroup', '移动到分组')}</Text>
            <Text size="xs" c="dimmed">{t('shelf.selectedBooksCount', '已选择 {{count}} 本书籍', { count: selectedCount })}</Text>
          </Stack>
          <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" size={16} />
          </ActionIcon>
        </Group>

        <ScrollArea.Autosize mah={320} offsetScrollbars>
          <Stack gap="xs">
            <Paper
              component="button"
              type="button"
              p="sm"
              withBorder
              radius="md"
              disabled={busy}
              onClick={() => void handleSelect(null)}
              className="legado-interactive-card"
              style={{ textAlign: 'left', cursor: 'pointer' }}
            >
              <Text size="sm" fw={600}>{t('search.scopeUngrouped', '未分组')}</Text>
              <Text size="xs" c="dimmed">{t('shelf.clearGroupBelonging', '清除当前分组归属')}</Text>
            </Paper>
            {groups.map(g => (
              <Paper
                key={g.id}
                component="button"
                type="button"
                p="sm"
                withBorder
                radius="md"
                disabled={busy}
                onClick={() => void handleSelect(g.name)}
                className="legado-interactive-card"
                style={{ textAlign: 'left', cursor: 'pointer' }}
              >
                <Group justify="space-between">
                  <Text size="sm" fw={600}>{g.name}</Text>
                  <Badge size="xs" variant="light" color="gray">
                    {t('shelf.booksInGroup', '{{count}} 本书', { count: g.bookCount })}
                  </Badge>
                </Group>
              </Paper>
            ))}
          </Stack>
        </ScrollArea.Autosize>
      </Stack>
    </Modal>
  )
}

/**
 * 用户点「缓存」之后**无论如何都继续轮询**的宽限期（毫秒）。
 *
 * 存在的理由见 `ShelfPage` 里 `pollGraceRef` 的注释：服务端在「入队 → 第一章进度登账」
 * 之间会短暂报 ready/idle，而轮询门只认 `cacheState === 'caching'`。没有宽限期，
 * 一拍踩空就会永久熄火（表现为「退回书架后缓存不动了」）。
 */
const CACHE_POLL_GRACE_MS = 30_000
const SHELF_REFRESH_POLL_MS = 900
const SHELF_REFRESH_ONLY_FINISHED_KEY = 'legado-shelf-refresh-only-finished-v1'

function needsShelfAttention(item: BookshelfItem) {
  return item.cacheState === 'failed' || item.cacheState === 'paused' || item.updateError
}

function hasCacheTask(item: BookshelfItem) {
  return item.cacheState === 'pending' || item.cacheState === 'caching'
}

function canRefreshBook(item: BookshelfItem) {
  return item.canUpdate !== false && !isLocalBook(item)
}

function readOnlyFinishedPreference(group: string): boolean {
  try {
    const raw = localStorage.getItem(SHELF_REFRESH_ONLY_FINISHED_KEY)
    if (!raw) return false
    const parsed = JSON.parse(raw) as unknown
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return false
    const values = parsed as Record<string, unknown>
    return values[group] === true
  } catch {
    return false
  }
}

function saveOnlyFinishedPreference(group: string, value: boolean) {
  try {
    const raw = localStorage.getItem(SHELF_REFRESH_ONLY_FINISHED_KEY)
    const parsed = raw ? JSON.parse(raw) as unknown : null
    const values = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {}
    values[group] = value
    localStorage.setItem(SHELF_REFRESH_ONLY_FINISHED_KEY, JSON.stringify(values))
  } catch {
    // 隐私模式下 localStorage 可能不可用；刷新本身仍可正常使用。
  }
}

function ShelfBookDetailModal({
  item,
  source,
  onClose,
  onRead,
  onManage,
  onShelfChanged,
}: {
  item: BookshelfItem
  source?: SourceSummary
  onClose: () => void
  onRead: () => void
  onManage: () => void
  onShelfChanged: () => void
}) {
  const { t } = useTranslation()
  const [details, setDetails] = useState<BookDetails | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [introExpanded, setIntroExpanded] = useState(false)
  const [loginOpen, setLoginOpen] = useState(false)
  const detailsRequest = useRef<AbortController | null>(null)
  const canLogin = !isLocalBook(item) && source?.hasLogin !== false

  useEffect(() => {
    const controller = new AbortController()
    detailsRequest.current = controller
    setDetails(null)
    setError('')
    setLoading(true)
    void api.details(item.sourceId, item.bookUrl, {
      name: item.name,
      author: item.author,
      tocUrl: item.tocUrl,
      bookKind: item.bookKind,
      variables: parseBookVariables(item.variable),
    }, controller.signal).then(fresh => {
      if (!controller.signal.aborted) setDetails(fresh)
    }).catch(cause => {
      if (!controller.signal.aborted) {
        setError(cause instanceof Error ? cause.message : t('shelf.detailsLoadFailed', '无法从书源更新详情，已显示书架中的已有信息'))
      }
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => controller.abort()
  }, [item.author, item.bookKind, item.bookUrl, item.name, item.sourceId, item.tocUrl, item.variable, t])

  const name = cleanTitle(details?.name || item.name) || item.name
  const author = cleanAuthor(details?.author || item.author || '') || t('common.unknownAuthor', '未知作者')
  const resolvedKind = details?.bookKind || item.bookKind
  const kind = isLocalBook(item) || resolvedKind === 'local'
    ? t('shelf.localTag', '本地')
    : resolvedKind === 'comic'
      ? t('shelf.comicTag', '漫画')
      : resolvedKind === 'audio'
        ? t('shelf.audioTag', '听书')
        : t('shelf.novelTag', '小说')
  const latestChapter = details?.lastChapter?.trim() || item.latestChapterTitle || undefined
  const chapterIndex = item.chapterIndex == null ? null : item.chapterIndex + 1
  const status = item.isReadFinished
    ? t('shelf.statusRead', '已读')
    : item.isReading
      ? t('shelf.statusReading', '在读')
      : item.isUnread
        ? t('shelf.statusUnread', '未读')
        : item.completed
          ? t('shelf.completed', '已读完')
          : item.chapterIndex === undefined
            ? t('shelf.justAdded', '刚加入书架')
            : t('shelf.readingProgress', '读至：{{chapter}}', { chapter: t('shelf.chapterAt', '第 {{count}} 章', { count: item.chapterIndex + 1 }) })

  const dialog = (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      zIndex={305}
      withCloseButton={false}
      closeOnEscape={!loginOpen}
      closeOnClickOutside={!loginOpen}
      trapFocus={!loginOpen}
      padding="lg"
      aria-label={t('shelf.bookDetailWithTitle', '书籍详情: {{name}}', { name: item.name })}
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" wrap="nowrap" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
          <Group align="flex-start" wrap="nowrap" gap="md" style={{ flex: 1, minWidth: 0 }}>
            <Box w={84} className="legado-cover-frame">
              <BookCover
                coverKey={item.coverKey}
                coverUrl={details?.coverUrl || item.coverUrl}
                name={name}
              />
            </Box>
            <Stack gap={4} style={{ flex: 1, minWidth: 0 }}>
              <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
                {t('shelf.bookDetail', '书籍详情')}
              </Text>
              <Title order={4} lineClamp={2}>{name}</Title>
              <Text size="sm" c="dimmed">{author}</Text>
              <Group gap={6} wrap="wrap" mt={4}>
                <Badge size="xs" variant="light" color="brand">{kind}</Badge>
                <Badge size="xs" variant="light" color={item.isReadFinished ? 'teal' : 'gray'}>{status}</Badge>
                <Badge size="xs" variant="outline" color="gray">
                  {t('reader.totalChapters', '{{count}} 章', { count: item.catalogChapters || item.totalChapters || 0 })}
                </Badge>
              </Group>
              {latestChapter && (
                <Text size="xs" c="dimmed" truncate title={latestChapter}>
                  {t('shelf.latestChapterWithTitle', '最新：{{title}}', { title: latestChapter })}
                </Text>
              )}
            </Stack>
          </Group>
          <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" size={16} />
          </ActionIcon>
        </Group>

        <ScrollArea.Autosize mah="62vh" offsetScrollbars>
          <Stack gap="md" pr={4}>
            {loading && (
              <Group gap="xs" role="status">
                <Loader size="xs" />
                <Text size="xs" c="dimmed">{t('shelf.loadingDetails', '正在从书源更新书籍详情...')}</Text>
              </Group>
            )}
            {error && (
              <Alert color="yellow" variant="light" p="xs" role="status">
                <Text size="xs">{error}</Text>
              </Alert>
            )}

            <SimpleGrid cols={{ base: 2, sm: 3 }} spacing="xs">
              <Paper p="xs" withBorder radius="md">
                <Text size="xs" c="dimmed">{t('shelf.readingStatus', '阅读状态')}</Text>
                <Text size="sm" fw={600} mt={2}>{status}</Text>
              </Paper>
              <Paper p="xs" withBorder radius="md">
                <Text size="xs" c="dimmed">{t('shelf.readingProgressLabel', '阅读进度')}</Text>
                <Text size="sm" fw={600} mt={2}>
                  {chapterIndex == null
                    ? t('shelf.notStarted', '尚未开始')
                    : `${chapterIndex} / ${item.catalogChapters || item.totalChapters || '?'}`}
                </Text>
              </Paper>
              <Paper p="xs" withBorder radius="md">
                <Text size="xs" c="dimmed">{t('shelf.group', '所属分组')}</Text>
                <Text size="sm" fw={600} mt={2} truncate>{item.groupName || t('search.scopeUngrouped', '未分组')}</Text>
              </Paper>
              <Paper p="xs" withBorder radius="md">
                <Text size="xs" c="dimmed">{t('shelf.cacheStatus', '离线缓存')}</Text>
                <Text size="sm" fw={600} mt={2}>{item.cachedChapters} / {item.totalChapters || item.catalogChapters || '?'}</Text>
              </Paper>
              <Paper p="xs" withBorder radius="md">
                <Text size="xs" c="dimmed">{t('shelf.updateStatus', '目录更新')}</Text>
                <Text size="sm" fw={600} mt={2} c={item.updateError ? 'red' : undefined}>
                  {item.canUpdate === false
                    ? t('shelf.updatesPaused', '已停更')
                    : item.updateError
                      ? t('shelf.refreshFailedShort', '更新失败')
                      : t('shelf.updatesEnabled', '已启用')}
                </Text>
              </Paper>
              {details?.kind && (
                <Paper p="xs" withBorder radius="md">
                  <Text size="xs" c="dimmed">{t('shelf.category', '分类')}</Text>
                  <Text size="sm" fw={600} mt={2} truncate>{details.kind}</Text>
                </Paper>
              )}
              {details?.wordCount && (
                <Paper p="xs" withBorder radius="md">
                  <Text size="xs" c="dimmed">{t('library.wordCount', '字数')}</Text>
                  <Text size="sm" fw={600} mt={2}>{details.wordCount}</Text>
                </Paper>
              )}
              <Paper p="xs" withBorder radius="md" style={{ gridColumn: '1 / -1' }}>
                <Text size="xs" c="dimmed">{t('shelf.source', '书源')}</Text>
                <Text size="xs" fw={500} mt={2} truncate title={item.sourceId} style={{ fontFamily: 'var(--mantine-font-family-monospace)' }}>
                  {item.sourceId}
                </Text>
              </Paper>
            </SimpleGrid>

            <Paper p="sm" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
              <Stack gap="xs">
                <Text size="xs" fw={700} c="dimmed">{t('shelf.bookIntro', '书籍简介')}</Text>
                {details?.intro ? (
                  <>
                    <Text
                      size="sm"
                      lineClamp={introExpanded ? undefined : 4}
                      style={{ whiteSpace: 'pre-line', lineHeight: 1.7 }}
                    >
                      {details.intro}
                    </Text>
                    {details.intro.length > 140 && (
                      <Button
                        size="compact-xs"
                        variant="subtle"
                        w="fit-content"
                        onClick={() => setIntroExpanded(value => !value)}
                      >
                        {introExpanded ? t('shelf.collapseIntro', '收起简介') : t('shelf.expandIntro', '展开简介')}
                      </Button>
                    )}
                  </>
                ) : !loading ? (
                  <Text size="sm" c="dimmed">{t('shelf.noIntro', '该书源没有提供简介')}</Text>
                ) : null}
              </Stack>
            </Paper>
          </Stack>
        </ScrollArea.Autosize>

        <Group justify="flex-end" gap="xs" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
          {canLogin && (
            <Button variant="subtle" leftSection={<Icon name="key" size={15} />} onClick={() => setLoginOpen(true)}>
              {t('source.loginButton', '登录')}
            </Button>
          )}
          <Button
            variant="default"
            leftSection={<Icon name="settings" size={15} />}
            onClick={onManage}
          >
            {t('shelf.bookManage', '书籍管理')}
          </Button>
          <Button
            leftSection={<Icon name="book" size={15} />}
            onClick={onRead}
          >
            {t('shelf.readNow', '查看正文')}
          </Button>
        </Group>
      </Stack>
    </Modal>
  )
  return (
    <>
      {dialog}
      {loginOpen && (
        <SourceLoginModal
          sourceId={item.sourceId}
          sourceName={source?.name}
          context={{
            book: {
              sourceId: item.sourceId,
              bookUrl: item.bookUrl,
              name,
              author: details?.author || item.author,
              tocUrl: details?.tocUrl || item.tocUrl,
              bookKind: resolvedKind,
              variables: details?.variables ?? parseBookVariables(item.variable),
            },
          }}
          onBookRefresh={refresh => {
            if (refresh.details) {
              detailsRequest.current?.abort()
              setLoading(false)
              setError('')
            }
            setDetails(current => {
              const fresh = refresh.details ?? current
              return fresh && {
                ...fresh,
                tocUrl: refresh.tocUrl ?? fresh.tocUrl,
                lastChapter: refresh.chapters?.at(-1)?.title ?? fresh.lastChapter,
                variables: refresh.variables ?? fresh.variables,
              }
            })
            if (refresh.chapters || refresh.variables) onShelfChanged()
          }}
          onClose={() => setLoginOpen(false)}
          onToast={toast.show}
        />
      )}
    </>
  )
}

export default function ShelfPage({ onOpenBook, onOpenTasks, onTaskCountChange, sources, theme }: {
  onOpenBook: (item: BookshelfItem) => void
  onOpenTasks: () => void
  onTaskCountChange: (count: number) => void
  sources: SourceSummary[]
  theme: ReaderTheme
}) {
  const { t } = useTranslation()
  const [items, setItems] = useState<BookshelfItem[]>([])
  const [groups, setGroups] = useState<BookGroup[]>([])
  const [selectedGroup, setSelectedGroup] = useState<string>('all') // 'all' | '__ungrouped__' | custom group name
  const [statusFilter, setStatusFilter] = useState<'all' | 'unread' | 'reading' | 'finished' | 'attention'>('all')
  const filterSurfaceRef = useRef<HTMLDivElement>(null)
  const [message, setMessage] = useState('')
  const [switchingItem, setSwitchingItem] = useState<BookshelfItem | null>(null)
  const [exportingItem, setExportingItem] = useState<BookshelfItem | null>(null)
  const [detailItem, setDetailItem] = useState<BookshelfItem | null>(null)
  /**
   * 书籍管理（一级）与「清除缓存」范围选择（二级）的**层级状态机**（见 `src/shelfModalStack.ts`）。
   *
   * 修复 issue #66：原先这里是两个彼此独立的可空状态，打开二级时把一级置 `null`，
   * 于是二级的「取消」只关掉自己 ⇒ 两级一起消失、回到书架，与文案「返回书籍管理」矛盾。
   * 现在层级只有这一份状态，`closeClearCacheScope` 只退一级 ⇒ 一级的书永远还在。
   */
  const [shelfModal, dispatchShelfModal] = useReducer(shelfModalReducer, SHELF_MODAL_SHELF)
  /** 当前可见的一级 / 二级（两者**互斥**：同一时刻最多一个非 null ⇒ 不会双层遮罩）。 */
  const managingItem = shelfModal.layer === 'manage' ? shelfModal.item : null
  const clearingCacheItem = shelfModal.layer === 'clearCacheScope' ? shelfModal.item : null
  const [clearingCache, setClearingCache] = useState(false)
  const [clearingScope, setClearingScope] = useState<ClearCacheScope | null>(null)
  const [uploading, setUploading] = useState(false)
  const [dragOver, setDragOver] = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [managingGroups, setManagingGroups] = useState(false)
  const [batchMode, setBatchMode] = useState(false)
  const [selectedKeys, setSelectedKeys] = useState<Set<string>>(new Set())
  const [batchMoving, setBatchMoving] = useState(false)
  const previousStateRef = useRef<Map<string, string>>(new Map())
  const [refreshStatus, setRefreshStatus] = useState<BookshelfRefreshStatus | null>(null)
  const refreshWasRunningRef = useRef(false)
  const [refreshStarting, setRefreshStarting] = useState(false)
  const [onlyFinishedRefresh, setOnlyFinishedRefresh] = useState(() => readOnlyFinishedPreference('all'))
  const [updatingRefreshSettingKey, setUpdatingRefreshSettingKey] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const [list, groupList] = await Promise.all([
        api.bookshelf(),
        api.bookGroups(),
      ])
      list.forEach(curr => {
        const key = `${curr.sourceId}\u0000${curr.bookUrl}`
        const prevState = previousStateRef.current.get(key)
        const hadCacheTask = prevState === 'pending' || prevState === 'caching'
        if (hadCacheTask && curr.cacheState === 'ready') {
          toast.success(t('shelf.allCachedDone', '《{{name}}》全本离线缓存完成（共 {{count}} 章）', { name: curr.name, count: curr.cachedChapters }))
        } else if (hadCacheTask && curr.cacheState === 'failed') {
          toast.warning(t('shelf.cacheInterrupted', '《{{name}}》缓存中断：{{error}}', { name: curr.name, error: curr.cacheError || t('reader.incomplete', '未全部完成') }))
        }
        previousStateRef.current.set(key, curr.cacheState)
      })
      setItems(list)
      saveShelfSnapshot(list)
      setGroups(groupList)
      setDetailItem(current => current
        ? list.find(item => item.sourceId === current.sourceId && item.bookUrl === current.bookUrl) ?? null
        : null)
    } catch (error) {
      const snapshot = getShelfSnapshot()
      if (snapshot) {
        setItems(snapshot as BookshelfItem[])
        setMessage(t('shelf.offlineSnapshot', '服务器暂时不可用，正在显示本地书架快照'))
      } else {
        setMessage(error instanceof Error ? error.message : t('shelf.cannotLoad', '无法载入书架'))
      }
    }
  }, [t])

  useEffect(() => {
    void load()
  }, [load])

  const applyRefreshStatus = useCallback((status: BookshelfRefreshStatus) => {
    const wasRunning = refreshWasRunningRef.current
    setRefreshStatus(status)
    if (status.state === 'running') {
      refreshWasRunningRef.current = true
      return
    }
    if (!wasRunning) return

    refreshWasRunningRef.current = false
    void load()
    if (status.total === 0) {
      toast.info(t('shelf.refreshNoEligible', '当前范围内没有可刷新的在线书籍'))
      return
    }
    const newChapters = status.items.reduce((total, item) => total + Math.max(0, item.newChapters), 0)
    if (status.failed > 0) {
      toast.warning(t('shelf.refreshFinishedPartial', '目录刷新完成：成功 {{success}} 本，失败 {{failed}} 本，新增 {{chapters}} 章', {
        success: status.succeeded,
        failed: status.failed,
        chapters: newChapters,
      }))
    } else {
      toast.success(t('shelf.refreshFinished', '目录刷新完成：更新 {{count}} 本，新增 {{chapters}} 章', {
        count: status.succeeded,
        chapters: newChapters,
      }))
    }
  }, [load, t])

  useEffect(() => {
    let active = true
    void api.bookshelfRefreshStatus().then(status => {
      if (active) applyRefreshStatus(status)
    }).catch(() => undefined)
    return () => {
      active = false
    }
  }, [applyRefreshStatus])

  useEffect(() => {
    if (refreshStatus?.state !== 'running') return
    let active = true
    let polling = false
    const poll = async () => {
      if (polling) return
      polling = true
      try {
        const status = await api.bookshelfRefreshStatus()
        if (active) applyRefreshStatus(status)
      } catch {
        // 单次轮询失败不终止；下一次继续读取服务端任务状态。
      } finally {
        polling = false
      }
    }
    const timer = window.setInterval(() => void poll(), SHELF_REFRESH_POLL_MS)
    return () => {
      active = false
      window.clearInterval(timer)
    }
  }, [applyRefreshStatus, refreshStatus?.state])

  useEffect(() => {
    setOnlyFinishedRefresh(readOnlyFinishedPreference(selectedGroup))
  }, [selectedGroup])

  const setOnlyFinished = (value: boolean) => {
    setOnlyFinishedRefresh(value)
    saveOnlyFinishedPreference(selectedGroup, value)
  }

  const refreshBooks = async (targets: BookshelfRefreshTarget[], { onlyFinished = onlyFinishedRefresh, concurrency = 9 } = {}) => {
    if (refreshStarting || refreshStatus?.state === 'running') return
    if (targets.length === 0) {
      toast.info(t('shelf.refreshNothingSelected', '当前没有可刷新的书籍'))
      return
    }
    refreshWasRunningRef.current = true
    setRefreshStarting(true)
    try {
      const status = await api.refreshBookshelf({
        books: targets.map(({ sourceId, bookUrl }) => ({ sourceId, bookUrl })),
        onlyFinished,
        concurrency,
      })
      applyRefreshStatus(status)
    } catch (error) {
      refreshWasRunningRef.current = false
      toast.error(error instanceof Error ? error.message : t('shelf.refreshStartFailed', '无法开始刷新书架'))
    } finally {
      setRefreshStarting(false)
    }
  }

  const setCanUpdate = async (item: BookshelfItem, canUpdate: boolean) => {
    const key = `${item.sourceId}\u0000${item.bookUrl}`
    setUpdatingRefreshSettingKey(key)
    try {
      const updated = await api.setBookshelfCanUpdate(item.sourceId, item.bookUrl, canUpdate)
      setItems(values => values.map(value => value.sourceId === updated.sourceId && value.bookUrl === updated.bookUrl ? updated : value))
      dispatchShelfModal({ type: 'updateItem', item: updated })
      toast.success(canUpdate
        ? t('shelf.resumeUpdatesSuccess', '已恢复《{{name}}》的目录更新', { name: item.name })
        : t('shelf.pauseUpdatesSuccess', '已停止《{{name}}》的目录更新', { name: item.name }))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.updateRefreshSettingFailed', '更新目录设置失败'))
    } finally {
      setUpdatingRefreshSettingKey(null)
    }
  }

  const handleImportFiles = async (files: FileList | File[]) => {
    const list = Array.from(files).filter(f => {
      const n = f.name.toLowerCase()
      return n.endsWith('.txt') || n.endsWith('.epub') || n.endsWith('.text')
    })
    if (list.length === 0) {
      toast.warning(t('shelf.pleaseSelectEbook', '请选择 .txt 或 .epub 格式的电子书文件'))
      return
    }
    setUploading(true)
    toast.info(t('shelf.parsingImportingBooks', '正在解析并导入 {{count}} 本本地书籍...', { count: list.length }))
    try {
      const resp = await api.importLocalBooks(list)
      if (resp.imported > 0) {
        toast.success(t('shelf.importSuccessBooks', '成功导入 {{count}} 本本地书籍！', { count: resp.imported }))
      }
      if (resp.failed > 0) {
        const errorMsg = resp.results.filter(r => !r.success).map(r => `${r.filename}: ${r.error}`).join('; ')
        toast.error(t('shelf.importPartialFailedBooks', '部分书籍导入失败 ({{count}} 本): {{error}}', { count: resp.failed, error: errorMsg }))
      }
      await load()
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t('shelf.importLocalBooksFailed', '导入本地书籍失败'))
    } finally {
      setUploading(false)
    }
  }

  /**
   * 书架列表的进度轮询门。
   *
   * ## 为什么不能只写 `if (!caching) return`
   * `caching` 完全来自**服务端快照**。而服务端从"入队"到"第一章进度登账"之间有一小段
   * （抓目录 / 解析第一章清单，实测 300ms~数秒）状态接口返回空 ⇒ 列表这一拍是
   * `ready`/`idle` ⇒ 上面那个写法会**在这一次就 return，而且永远不再重新评估**
   * （没有定时器 ⇒ 没有新的 load() ⇒ `caching` 不会变）⇒ 用户看到「退到书架后缓存就不动了」。
   *
   * 因此：用户刚点过缓存 ⇒ 给一个**宽限期**，期间即使某一拍不是 caching 也继续轮询；
   * 宽限期结束后由定时器自己收尾（服务端那边已改成入队即登账，正常情况下这一拍就是 caching）。
   */
  const caching = items.some(hasCacheTask)
  const cachingRef = useRef(caching)
  cachingRef.current = caching
  const pollGraceRef = useRef(0)
  useEffect(() => {
    if (!caching && Date.now() > pollGraceRef.current) return
    const timer = window.setInterval(() => {
      if (!cachingRef.current && Date.now() > pollGraceRef.current) {
        // 宽限期过了且这一拍确实没在缓存 ⇒ 收尾，别让列表无意义地每秒重拉
        window.clearInterval(timer)
        return
      }
      void load()
    }, 1200)
    return () => window.clearInterval(timer)
  }, [caching, load])

  /**
   * 让**书籍管理弹窗**跟着列表一起刷新。
   *
   * 弹窗里的 item 是打开那一刻的**快照**，而进度是由上面那个定时 `load()` 写进 `items` 的。
   * 不把新进度回灌进弹窗，弹窗里的「x/y 章」就永远停在打开时的数字 —— 这正是用户反馈的
   * 「弹窗里的缓存还是有问题 / 缓存不动」：服务端在跑、列表也在涨，唯独弹窗那一份数据是死的。
   *
   * 回灌逻辑搬进状态机的 `syncSnapshot`：只同步**进度相关字段**，不动书名/封面等可编辑字段
   * （编辑流程走 `updateItem`），且「没变化就返回同一个 state」⇒ 不会多渲染一次。
   */
  useEffect(() => {
    dispatchShelfModal({ type: 'syncSnapshot', items })
  }, [items])

  const remove = async (item: BookshelfItem) => {
    if (!confirm(t('shelf.removeFromShelfConfirmDetailed', '移出“{{name}}”将清除书架、阅读进度和缓存封面，确定继续吗？', { name: item.name }))) return
    try {
      await api.removeFromBookshelf(item.sourceId, item.bookUrl)
      setItems(values => values.filter(value => value.sourceId !== item.sourceId || value.bookUrl !== item.bookUrl))
      toast.info(t('shelf.bookRemoved', '《{{name}}》已移出书架', { name: item.name }))
      void load()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.removeFailed', '移出失败'))
    }
  }

  const cache = async (item: BookshelfItem, chapterConcurrency?: number): Promise<boolean> => {
    try {
      await api.cacheBookshelfBook(item.sourceId, item.bookUrl, chapterConcurrency)
      // 宽限期：服务端「入队 → 第一章进度登账」之间有亚秒~数秒空窗（抓目录时更久），
      // 这段列表会报 ready/idle。不给宽限期的话轮询门会在这一拍永久熄火（见 pollGraceRef 注释）。
      pollGraceRef.current = Date.now() + CACHE_POLL_GRACE_MS
      setItems(values => values.map(value => value.sourceId === item.sourceId && value.bookUrl === item.bookUrl ? { ...value, cacheState: 'caching', cacheError: undefined } : value))
      previousStateRef.current.set(`${item.sourceId}\u0000${item.bookUrl}`, 'caching')
      toast.info(chapterConcurrency == null
        ? t('shelf.addedToCacheQueue', { name: item.name, defaultValue: `已加入离线缓存队列，正在下载《${item.name}》...` })
        : t('shelf.addedToCacheQueueWithConcurrency', {
            name: item.name,
            count: chapterConcurrency,
            defaultValue: `《${item.name}》已按 ${chapterConcurrency} 章并发加入缓存队列`,
          }))
      return true
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.cannotStartCache', '无法开始缓存'))
      return false
    }
  }

  const cancelCache = async (item: BookshelfItem) => {
    try {
      await api.cancelBookCache(item.sourceId, item.bookUrl)
      setItems(values => values.map(value => value.sourceId === item.sourceId && value.bookUrl === item.bookUrl ? { ...value, cacheState: 'failed', cacheError: t('shelf.cacheErrorCancelled', '已取消缓存') } : value))
      previousStateRef.current.set(`${item.sourceId}\u0000${item.bookUrl}`, 'failed')
      toast.info(t('shelf.cacheCancelled', '已取消《{{name}}》的离线缓存', { name: item.name }))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.cancelCacheFailed', '取消缓存失败'))
    }
  }

  /**
   * 按**用户选定的范围**清除这一本书已下载的缓存。
   *
   * 范围模型见 `shelfClearCache.ts`：`server` 只打三个服务端端点、`browser` 只清本机
   * IndexedDB、`both` 四步全做；**调用集合完全由 `stepsForScope(scope)` 决定**。
   *
   * 作用域**永远只带 `item.sourceId` + `item.bookUrl`**（用户口径：「只清这本书的」），
   * 四个步骤共用同一张表 ⇒ 不会出现"改了一条分支忘了另一条"而串范围。
   *
   * 每一步独立 `try/catch` 记账：只报「全成功」或「具体哪一部分没清掉」，
   * 且点名只点**实际执行过**的段（只清服务器时不会冒出「本机离线正文」）。
   */
  const clearCache = async (item: BookshelfItem, scope: ClearCacheScope) => {
    setClearingCache(true)
    setClearingScope(scope)
    const failedParts: string[] = []
    try {
      for (const step of stepsForScope(scope)) {
        try {
          if (step === 'content') {
            await api.clearBookCacheData(item.sourceId, item.bookUrl)
          } else {
            // 本机 IndexedDB 里的离线正文（「本机离线缓存管理」用的同一套存储）。按书删，不做全清。
            await clearOfflineBook(item.sourceId, item.bookUrl)
          }
        } catch {
          failedParts.push(
            step === 'content'
              ? t('shelf.clearCachePartContent', '正文缓存')
              : t('shelf.clearCachePartLocal', '本机离线正文'),
          )
        }
      }
    } finally {
      setClearingCache(false)
      setClearingScope(null)
      // 清理执行完的落点：**退回一级「书籍管理」**（与取消 / ESC / 点遮罩同一个转移）。
      // 为什么不是回书架：清缓存是从这本书的管理弹窗里发起的，执行完立刻在**同一本书**上
      // 看到「0 章已缓存」比把人踢回书架更符合最小惊讶，也省掉"再点进去确认"的一步。
      dispatchShelfModal({ type: 'closeClearCacheScope' })
    }
    if (failedParts.length === 0) {
      toast.success(t('shelf.clearCacheSuccess', '《{{name}}》缓存已清除', { name: item.name }))
    } else {
      toast.warning(t('shelf.clearCachePartial', '《{{name}}》部分缓存未清除：{{parts}}，可稍后重试', { name: item.name, parts: failedParts.join('、') }))
    }
    // 离线章数已归零：回书架拉一次最新状态，缓存进度条才不会停在旧值上
    void load()
  }

  const handleSwitchShelfSource = async (chosen: { result: SearchResult; chapters: Chapter[]; targetChapterIndex: number }) => {
    if (!switchingItem) return
    const details = await api.details(chosen.result.sourceId, chosen.result.bookUrl, {
      name: chosen.result.name || switchingItem.name,
      author: chosen.result.author || switchingItem.author,
      tocUrl: chosen.result.tocUrl,
      bookKind: chosen.result.bookKind || switchingItem.bookKind,
      variables: parseBookVariables(switchingItem.variable),
    })
    const fallbackCover = details.coverUrl?.trim() ||
      chosen.result.coverUrl?.trim() ||
      switchingItem.alternateSources?.find(s => s.coverUrl?.trim())?.coverUrl?.trim()

    await api.switchBookshelfSource({
      oldSourceId: switchingItem.sourceId,
      oldBookUrl: switchingItem.bookUrl,
      book: {
        sourceId: details.sourceId,
        bookUrl: chosen.result.bookUrl,
        name: cleanTitle(details.name?.trim() || switchingItem.name) || switchingItem.name,
        author: cleanAuthor(details.author?.trim() || switchingItem.author) || switchingItem.author,
        tocUrl: details.tocUrl,
        coverUrl: fallbackCover || undefined,
        groupName: switchingItem.groupName,
        catalogChapters: chosen.chapters.length,
      },
      alternateSources: switchingItem.alternateSources,
    })
    setSwitchingItem(null)
    await load()
  }

  const setCompleted = async (item: BookshelfItem, completed: boolean) => {
    try {
      const updated = await api.setBookshelfCompleted(item.sourceId, item.bookUrl, completed)
      setItems(values => values.map(value => value.sourceId === item.sourceId && value.bookUrl === item.bookUrl ? updated : value))
      toast.success(completed ? t('shelf.updateReadingStatusSuccess', '已将《{{name}}》标记为已读完', { name: item.name }) : t('shelf.updateReadingStatusResume', '已将《{{name}}》恢复为正在阅读', { name: item.name }))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.updateReadingStatusFailed', '更新阅读状态失败'))
    }
  }

  const cacheBadge = (item: BookshelfItem) => {
    if (isLocalBook(item)) {
      const count = item.cachedChapters || item.totalChapters || 0
      return count > 0 ? t('shelf.chaptersCached', '{{count}}章已缓存', { count }) : null
    }
    if (item.cacheState === 'pending') return t('shelf.cachePending', '缓存排队中')
    if (item.cacheState === 'caching') return `${Math.min(100, Math.round((item.cachedChapters / Math.max(1, item.totalChapters || 1)) * 100))}% ${t('shelf.caching', '缓存中')}`
    if (item.cacheState === 'ready') return t('shelf.chaptersCached', '{{count}}章已缓存', { count: item.cachedChapters })
    if (item.cacheState === 'failed') return `${item.cachedChapters}/${item.totalChapters || '?'} · ${t('shelf.cacheFailed', '缓存中断')}`
    if (item.cacheState === 'paused') return `${item.cachedChapters}/${item.totalChapters || '?'} · ${t('shelf.cachePaused', '缓存已暂停')}`
    return null
  }

  const groupFilteredItems = useMemo(() => {
    if (selectedGroup === 'all') return items
    if (selectedGroup === '__ungrouped__') return items.filter(i => !i.groupName)
    return items.filter(i => i.groupName === selectedGroup)
  }, [items, selectedGroup])

  const visibleItems = useMemo(() => {
    if (statusFilter === 'all') return groupFilteredItems
    if (statusFilter === 'attention') return groupFilteredItems.filter(needsShelfAttention)
    if (statusFilter === 'finished') return groupFilteredItems.filter(i => i.isReadFinished)
    if (statusFilter === 'reading') return groupFilteredItems.filter(i => i.isReading)
    return groupFilteredItems.filter(i => i.isUnread)
  }, [groupFilteredItems, statusFilter])

  const refreshStatusByBook = useMemo(() => {
    return new Map((refreshStatus?.items ?? []).map(item => [
      `${item.sourceId}\u0000${item.bookUrl}`,
      item,
    ]))
  }, [refreshStatus])

  const visibleRefreshableItems = useMemo(() => visibleItems.filter(item =>
    canRefreshBook(item) && (!onlyFinishedRefresh || item.isReadFinished)
  ), [onlyFinishedRefresh, visibleItems])

  const refreshRunning = refreshStarting || refreshStatus?.state === 'running'
  const refreshableBookKeys = useMemo(() => new Set(items.filter(canRefreshBook)
    .map(item => `${item.sourceId}\u0000${item.bookUrl}`)), [items])

  const renderRefreshRetry = (item: BookshelfRefreshTarget & { name: string }) => (
    <Button
      size="compact-xs"
      variant="light"
      color="red"
      leftSection={<Icon name="refresh" size={12} />}
      disabled={refreshRunning || !refreshableBookKeys.has(`${item.sourceId}\u0000${item.bookUrl}`)}
      onClick={() => void refreshBooks([item], { onlyFinished: false, concurrency: 1 })}
      aria-label={t('shelf.retryRefreshForBook', '重试《{{name}}》的目录刷新', { name: item.name })}
    >
      {t('shelf.retryRefresh', '重试目录')}
    </Button>
  )

  const showBooksNeedingAttention = () => {
    setSelectedGroup('all')
    setStatusFilter('attention')
    filterSurfaceRef.current?.scrollIntoView({ block: 'start' })
  }

  const groupCounts = useMemo(() => {
    let ungrouped = 0
    items.forEach(i => {
      if (!i.groupName) ungrouped++
    })
    return { ungrouped, all: items.length }
  }, [items])

  const statusCounts = useMemo(() => ({
    all: groupFilteredItems.length,
    unread: groupFilteredItems.filter(i => i.isUnread).length,
    reading: groupFilteredItems.filter(i => i.isReading).length,
    finished: groupFilteredItems.filter(i => i.isReadFinished).length,
    attention: groupFilteredItems.filter(needsShelfAttention).length,
  }), [groupFilteredItems])
  const shelfMetrics = useMemo(() => ({
    reading: items.filter(item => item.isReading).length,
    cached: items.filter(item => item.cacheState === 'ready').length,
    interrupted: items.filter(needsShelfAttention).length,
  }), [items])

  const continueReading = useMemo(() => (
    [...items]
      .filter(item => item.isReading && !item.isReadFinished)
      .sort((left, right) => right.lastReadAt - left.lastReadAt)
      .slice(0, 3)
  ), [items])

  useEffect(() => {
    const activeCache = items.filter(hasCacheTask).length
    const refreshTasks = refreshStatus?.state === 'running' ? 1 : 0
    onTaskCountChange(activeCache + refreshTasks + shelfMetrics.interrupted)
  }, [items, onTaskCountChange, refreshStatus?.state, shelfMetrics.interrupted])

  const toggleSelectKey = (key: string) => {
    setSelectedKeys(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  const selectAllVisible = () => {
    const keys = visibleItems.map(i => `${i.sourceId}\u0000${i.bookUrl}`)
    setSelectedKeys(new Set(keys))
  }

  const deselectAll = () => {
    setSelectedKeys(new Set())
  }

  const getSelectedBookKeys = () => {
    return Array.from(selectedKeys).map(k => {
      const parts = k.split('\u0000')
      return { sourceId: parts[0], bookUrl: parts[1] }
    })
  }

  const handleBatchMoveGroup = async (targetGroup: string | null) => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    try {
      await api.batchBookshelf({
        action: 'move_group',
        items: keys,
        targetGroup: targetGroup || undefined,
      })
      toast.success(targetGroup ? t('shelf.batchMovedToGroup', '已将 {{count}} 本书籍移动至「{{group}}」', { count: keys.length, group: targetGroup }) : t('shelf.batchMovedToUngrouped', '已将 {{count}} 本书籍移至「未分组」', { count: keys.length }))
      setSelectedKeys(new Set())
      setBatchMode(false)
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchMoveFailed', '批量移动失败'))
    }
  }

  const handleBatchMarkCompleted = async (completed: boolean) => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    try {
      await api.batchBookshelf({
        action: 'mark_completed',
        items: keys,
        completed,
      })
      toast.success(completed ? t('shelf.batchMarkCompletedSuccess', '已将 {{count}} 本书籍标记为已读完', { count: keys.length }) : t('shelf.batchMarkReadingSuccess', '已将 {{count}} 本书籍恢复为正在阅读', { count: keys.length }))
      setSelectedKeys(new Set())
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchUpdateStatusFailed', '批量更新阅读状态失败'))
    }
  }

  const handleBatchDelete = async () => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    if (!confirm(t('shelf.batchDeleteConfirm', '确定将选中的 {{count}} 本书籍移出书架吗？将清除阅读进度与离线缓存。', { count: keys.length }))) return
    try {
      await api.batchBookshelf({
        action: 'delete',
        items: keys,
      })
      toast.info(t('shelf.batchRemovedSuccess', '已移出 {{count}} 本书籍', { count: keys.length }))
      setSelectedKeys(new Set())
      setBatchMode(false)
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchDeleteFailed', '批量移出失败'))
    }
  }

  const handleBatchReclean = async () => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    try {
      const res = await api.batchRecleanBookCache(keys)
      toast.success(t('shelf.batchRecleanSuccess', '批量重洗完成，共处理 {{count}} 章', { count: res.totalRecleaned }))
      setSelectedKeys(new Set())
      setBatchMode(false)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchRecleanFailed', '批量重洗失败'))
    }
  }

  return (
    <Box
      component="main"
      className={dragOver ? 'legado-dropzone-active' : undefined}
      style={{ borderRadius: 12 }}
      onDragOver={e => { e.preventDefault(); setDragOver(true) }}
      onDragLeave={e => {
        if (!e.currentTarget.contains(e.relatedTarget as Node)) {
          setDragOver(false)
        }
      }}
      onDrop={e => {
        e.preventDefault()
        setDragOver(false)
        if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
          void handleImportFiles(e.dataTransfer.files)
        }
      }}
    >
      <Stack gap="lg">
        {/* Page Header */}
        <Group justify="space-between" align="flex-end" wrap="wrap" gap="md">
          <Stack gap={2}>
            <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.8}>
              {t('shelf.headerTitle', '我的书架')}
            </Text>
            <Title order={2}>{t('header.shelf', '书架')}</Title>
            <Text size="sm" c="dimmed">查看阅读进度与缓存状态，整理分组并从封面直接继续阅读。</Text>
          </Stack>

          <Group gap="xs" wrap="wrap">
            <Button.Group>
              <Button
                size="sm"
                variant="default"
                loading={refreshRunning}
                disabled={refreshRunning || uploading || visibleRefreshableItems.length === 0}
                leftSection={!refreshRunning ? <Icon name="refresh" size={15} /> : undefined}
                onClick={() => void refreshBooks(visibleItems)}
                title={t('shelf.refreshCurrentScopeHint', '更新当前分组与状态筛选中的在线书籍目录')}
              >
                {refreshRunning
                  ? t('shelf.refreshingProgress', '刷新中 {{completed}}/{{total}}', {
                      completed: refreshStatus?.completed ?? 0,
                      total: refreshStatus?.total ?? 0,
                    })
                  : t('shelf.refreshCurrentScope', '更新当前书架')}
              </Button>
              <Menu position="bottom-end" withinPortal closeOnItemClick={false}>
                <Menu.Target>
                  <Button
                    size="sm"
                    variant="default"
                    px="xs"
                    disabled={refreshRunning}
                    aria-label={t('shelf.refreshOptions', '更新选项')}
                  >
                    <Icon name="chevronDown" size={14} />
                  </Button>
                </Menu.Target>
                <Menu.Dropdown>
                  <Menu.Label>{t('shelf.refreshOptions', '目录更新选项')}</Menu.Label>
                  <Menu.Item onClick={() => setOnlyFinished(!onlyFinishedRefresh)}>
                    <Checkbox
                      size="xs"
                      checked={onlyFinishedRefresh}
                      onChange={() => undefined}
                      label={t('shelf.refreshOnlyFinished', '仅更新已读完')}
                      description={t('shelf.refreshOnlyFinishedHint', '刷新时只处理已经没有未读章节的书籍')}
                      readOnly
                    />
                  </Menu.Item>
                </Menu.Dropdown>
              </Menu>
            </Button.Group>

            <input
              ref={fileInputRef}
              type="file"
              multiple
              accept=".txt,.epub,.text,application/epub+zip,text/plain"
              style={{ display: 'none' }}
              onChange={e => {
                if (e.target.files && e.target.files.length > 0) {
                  void handleImportFiles(e.target.files)
                  e.target.value = ''
                }
              }}
            />
            <Button
              size="sm"
              variant="default"
              loading={uploading}
              leftSection={!uploading ? <Icon name="upload" size={15} /> : undefined}
              onClick={() => fileInputRef.current?.click()}
              title={t('shelf.importBook', '导入本地图书')}
            >
              {uploading ? t('common.loading', '导入中...') : t('shelf.importBook', '导入本地')}
            </Button>

            <Button
              size="sm"
              variant={batchMode ? 'filled' : 'light'}
              color={batchMode ? 'brand' : 'gray'}
              leftSection={<Icon name={batchMode ? 'check' : 'list'} size={15} />}
              onClick={() => {
                if (batchMode) {
                  setBatchMode(false)
                  setSelectedKeys(new Set())
                } else {
                  setBatchMode(true)
                }
              }}
            >
              {batchMode ? t('common.ok', '完成') : t('shelf.batchManage', '批量管理')}
            </Button>
          </Group>
        </Group>

        {/* Continue Reading & Readiness */}
        {(continueReading.length > 0 || shelfMetrics.interrupted > 0) && (
          <Grid gutter="md">
            {continueReading.length > 0 && (
              <Grid.Col span={{ base: 12, lg: 8 }}>
              <Paper p="md" withBorder radius="lg" h="100%">
                <Stack gap="sm">
                  <Group justify="space-between" align="center">
                    <Group gap="xs">
                      <ThemeIcon size={26} radius="md" variant="light" color="brand">
                        <Icon name="bookmark" size={14} />
                      </ThemeIcon>
                      <Text fw={700} size="sm">继续阅读</Text>
                    </Group>
                    <Text size="xs" c="dimmed">最近打开的在线书</Text>
                  </Group>
                  <SimpleGrid cols={{ base: 1, sm: 3 }} spacing="xs">
                    {continueReading.map(item => {
                      const total = item.catalogChapters || item.totalChapters || 0
                      const current = total > 0 ? Math.min(total, (item.chapterIndex ?? 0) + 1) : 0
                      return (
                        <Paper
                          key={`${item.sourceId}\u0000${item.bookUrl}`}
                          component="button"
                          type="button"
                          p="xs"
                          withBorder
                          radius="md"
                          className="legado-interactive-card"
                          onClick={() => onOpenBook(item)}
                          style={{ textAlign: 'left', width: '100%', cursor: 'pointer' }}
                        >
                          <Group wrap="nowrap" gap="sm" align="center">
                            <Box w={44} className="legado-cover-frame">
                              <BookCover coverKey={item.coverKey} coverUrl={item.coverUrl} name={item.name} />
                            </Box>
                            <Stack gap={2} style={{ flex: 1, minWidth: 0 }}>
                              <Text size="sm" fw={600} lineClamp={1}>{item.name}</Text>
                              <Text size="xs" c="dimmed" truncate>
                                {current > 0 ? `第 ${current} 章` : '从开头继续'}
                                {total > 0 ? ` · ${current}/${total}` : ''}
                              </Text>
                            </Stack>
                            <Box c="dimmed">
                              <Icon name="chevronRight" size={15} />
                            </Box>
                          </Group>
                        </Paper>
                      )
                    })}
                  </SimpleGrid>
                </Stack>
              </Paper>
              </Grid.Col>
            )}

            <Grid.Col span={{ base: 12, lg: continueReading.length > 0 ? 4 : 12 }}>
            <Paper p="md" withBorder radius="lg" h="100%">
              <Stack gap="sm" h="100%" justify="space-between">
                <Group justify="space-between" align="center">
                  <Group gap="xs">
                    <ThemeIcon
                      size={26}
                      radius="md"
                      variant="light"
                      color={shelfMetrics.interrupted > 0 ? 'gold' : 'teal'}
                    >
                      <Icon name={shelfMetrics.interrupted > 0 ? 'alert' : 'check'} size={14} />
                    </ThemeIcon>
                    <Text fw={700} size="sm">阅读准备情况</Text>
                  </Group>
                  <Badge size="xs" variant="light" color={shelfMetrics.interrupted > 0 ? 'gold' : 'teal'}>
                    {shelfMetrics.interrupted > 0 ? `${shelfMetrics.interrupted} 本需处理` : '状态正常'}
                  </Badge>
                </Group>

                <Group align="baseline" gap="sm">
                  <Text fz={28} fw={700} lh={1}>{shelfMetrics.cached}</Text>
                  <Stack gap={0}>
                    <Text size="sm" fw={600}>本已离线缓存</Text>
                    <Text size="xs" c="dimmed">
                      {shelfMetrics.interrupted > 0
                        ? `${shelfMetrics.interrupted} 本缓存或目录异常`
                        : `共 ${items.length} 本书，${shelfMetrics.reading} 本在读`}
                    </Text>
                  </Stack>
                </Group>

                {shelfMetrics.interrupted > 0 ? (
                  <Button
                    size="xs"
                    variant="light"
                    color="gold"
                    rightSection={<Icon name="arrowRight" size={13} />}
                    onClick={showBooksNeedingAttention}
                  >
                    {t('shelf.viewBooksNeedingAttention', '查看需要处理的书')}
                  </Button>
                ) : (
                  <Button
                    size="xs"
                    variant="default"
                    rightSection={<Icon name="arrowRight" size={13} />}
                    onClick={() => setBatchMode(true)}
                  >
                    选择书籍批量管理
                  </Button>
                )}
              </Stack>
            </Paper>
            </Grid.Col>
          </Grid>
        )}

        <AutomationCenter
          items={items}
          refreshStatus={refreshStatus}
          caching={caching}
          onOpenBook={item => dispatchShelfModal({ type: 'openManage', item })}
          onOpenTasks={onOpenTasks}
        />

        {/* Group & Status Filters */}
        <Paper ref={filterSurfaceRef} p="md" withBorder radius="lg">
          <Stack gap="sm">
            <Group justify="space-between" align="center" wrap="wrap" gap="xs">
              <Tabs
                value={selectedGroup}
                onChange={value => value && setSelectedGroup(value)}
                variant="pills"
                style={{ flex: 1, minWidth: 0 }}
              >
                <Tabs.List style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>
                  <Tabs.Tab value="all" rightSection={<Badge size="xs" variant="light" color="gray">{groupCounts.all}</Badge>}>
                    {t('common.all', '全部')}
                  </Tabs.Tab>
                  <Tabs.Tab value="__ungrouped__" rightSection={<Badge size="xs" variant="light" color="gray">{groupCounts.ungrouped}</Badge>}>
                    {t('search.scopeUngrouped', '未分组')}
                  </Tabs.Tab>
                  {groups.map(g => (
                    <Tabs.Tab key={g.id} value={g.name} rightSection={<Badge size="xs" variant="light" color="gray">{g.bookCount}</Badge>}>
                      {g.name}
                    </Tabs.Tab>
                  ))}
                </Tabs.List>
              </Tabs>

              <Button
                size="xs"
                variant="subtle"
                leftSection={<Icon name="settings" size={14} />}
                onClick={() => setManagingGroups(true)}
                title={t('shelf.manageGroups', '管理与创建分组')}
              >
                {t('shelf.manageGroups', '管理分组')}
              </Button>
            </Group>

            <Divider />

            <Group justify="space-between" align="center" wrap="wrap" gap="xs">
              <Group gap={6} wrap="wrap">
                {([
                  ['all', t('common.all', '全部')],
                  ['unread', t('shelf.statusUnread', '未读')],
                  ['reading', t('shelf.statusReading', '在读')],
                  ['finished', t('shelf.statusRead', '已读')],
                  ['attention', t('shelf.statusAttention', '需处理')],
                ] as const).map(([key, label]) => (
                  <Button
                    key={key}
                    size="compact-sm"
                    variant={statusFilter === key ? 'filled' : 'light'}
                    color={statusFilter === key ? (key === 'attention' ? 'gold' : 'brand') : 'gray'}
                    aria-pressed={statusFilter === key}
                    onClick={() => setStatusFilter(key)}
                  >
                    {label} ({statusCounts[key]})
                  </Button>
                ))}
              </Group>
              <Text size="xs" c="dimmed">
                {t('shelf.bookCount', { count: visibleItems.length, defaultValue: `当前显示 ${visibleItems.length} 本` })}
              </Text>
            </Group>
          </Stack>
        </Paper>

        {message && (
          <Alert color="yellow" variant="light" icon={<Icon name="alert" size={16} />}>
            <Text size="sm">{message}</Text>
          </Alert>
        )}

        {refreshStatus && refreshStatus.total > 0 && (refreshStatus.state === 'running' || refreshStatus.failed > 0) && (
          <Paper p="sm" withBorder radius="md" style={{ borderColor: refreshStatus.failed > 0 && refreshStatus.state !== 'running' ? 'var(--warning)' : 'var(--accent)' }}>
            <Stack gap="xs">
              <Group justify="space-between" align="center">
                <Group gap="xs" role="status">
                  <Icon name={refreshStatus.state === 'running' ? 'refresh' : 'activity'} size={16} className={refreshStatus.state === 'running' ? 'spin' : undefined} />
                  <Text size="sm" fw={600}>
                    {refreshStatus.state === 'running'
                      ? t('shelf.refreshingBooks', '正在刷新目录')
                      : t('shelf.refreshCompletedWithFailures', '目录刷新完成')}
                  </Text>
                </Group>
                <Badge size="sm" variant="light">
                  {refreshStatus.completed} / {refreshStatus.total}
                </Badge>
              </Group>
              <Progress
                value={Math.round((refreshStatus.completed / Math.max(1, refreshStatus.total)) * 100)}
                animated={refreshStatus.state === 'running'}
                size="sm"
                radius="xl"
              />
              {refreshStatus.failed > 0 && (
                <Stack gap={6}>
                  {refreshStatus.items.filter(item => item.state === 'failed').map(item => (
                    <Group key={`${item.sourceId}\u0000${item.bookUrl}`} justify="space-between" gap="xs" wrap="wrap">
                      <Text size="xs" c="red" style={{ flex: 1, minWidth: 0 }} truncate>
                        {item.name}{item.error ? `：${item.error}` : ''}
                      </Text>
                      {renderRefreshRetry(item)}
                    </Group>
                  ))}
                </Stack>
              )}
            </Stack>
          </Paper>
        )}

        {/* Shelf Content */}
        {items.length === 0 && !message ? (
          <Paper p="xl" withBorder radius="lg">
            <Center py="xl">
              <Stack align="center" gap="sm" ta="center">
                <ThemeIcon size={52} radius="xl" variant="light" color="brand">
                  <Icon name="book" size={26} />
                </ThemeIcon>
                <Title order={4}>{t('shelf.emptyTitle', '书架还是空的')}</Title>
                <Text size="sm" c="dimmed">从搜书页加入书籍，或直接拖拽导入本地 TXT / EPUB。</Text>
                <Button
                  mt="xs"
                  loading={uploading}
                  leftSection={!uploading ? <Icon name="upload" size={15} /> : undefined}
                  onClick={() => fileInputRef.current?.click()}
                >
                  {uploading ? t('common.loading', '正在解析导入...') : t('shelf.importBook', '导入本地 TXT / EPUB')}
                </Button>
              </Stack>
            </Center>
          </Paper>
        ) : visibleItems.length === 0 ? (
          <Paper p="xl" withBorder radius="lg">
            <Center py="xl">
              <Stack align="center" gap="xs" ta="center">
                <ThemeIcon size={48} radius="xl" variant="light" color="gray">
                  <Icon name="book" size={24} />
                </ThemeIcon>
                <Title order={4}>{t('shelf.emptyFilterTitle', '当前分组与筛选下没有书籍')}</Title>
              </Stack>
            </Center>
          </Paper>
        ) : (
          <SimpleGrid cols={{ base: 2, xs: 2, sm: 3, md: 4, lg: 5 }} spacing="md">
            {visibleItems.map(item => {
              const openItem = () => onOpenBook(item)
              const badge = cacheBadge(item)
              const isCaching = item.cacheState === 'caching'
              const percent = Math.min(100, Math.round((item.cachedChapters / Math.max(1, item.totalChapters || 1)) * 100))
              const itemKey = `${item.sourceId}\u0000${item.bookUrl}`
              const isSelected = selectedKeys.has(itemKey)
              const refreshItemStatus = refreshStatusByBook.get(itemKey)
              const isRefreshingItem = refreshItemStatus?.state === 'queued' || refreshItemStatus?.state === 'running'
              const readingTotal = item.catalogChapters || item.totalChapters || 0
              const readingChapter = readingTotal > 0
                ? item.isUnread && !item.isReadFinished
                  ? 0
                  : Math.min(readingTotal, item.chapterIndex == null ? 0 : item.chapterIndex + 1)
                : 0

              return (
                <Card
                  key={itemKey}
                  p="sm"
                  withBorder
                  radius="md"
                  className="legado-interactive-card"
                  onClick={batchMode ? () => toggleSelectKey(itemKey) : undefined}
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    cursor: batchMode ? 'pointer' : undefined,
                    borderColor: isSelected
                      ? 'var(--accent)'
                      : item.updateError
                        ? 'var(--danger)'
                        : undefined,
                    backgroundColor: isSelected ? 'var(--accent-soft)' : undefined,
                  }}
                >
                  {/* Cover */}
                  <Box
                    pos="relative"
                    className="legado-cover-frame"
                    style={{ cursor: 'pointer', width: '100%' }}
                    onClick={batchMode ? (e: React.MouseEvent) => { e.stopPropagation(); toggleSelectKey(itemKey) } : openItem}
                    role="button"
                    tabIndex={0}
                    onKeyDown={(e: React.KeyboardEvent) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault()
                        if (batchMode) toggleSelectKey(itemKey)
                        else openItem()
                      }
                    }}
                    aria-label={batchMode ? t('shelf.selectBook', '选择 {{name}}', { name: item.name }) : `查看正文 ${item.name}`}
                  >
                    <BookCover
                      coverKey={item.coverKey}
                      coverUrl={item.coverUrl}
                      name={item.name}
                    />
                    <ShelfKindTag bookKind={item.bookKind} local={isLocalBook(item)} />

                    {batchMode && (
                      <Box pos="absolute" top={8} left={8} style={{ zIndex: 3 }}>
                        <Checkbox
                          checked={isSelected}
                          onChange={() => undefined}
                          aria-hidden="true"
                          tabIndex={-1}
                        />
                      </Box>
                    )}

                    {badge && (
                      <Badge
                        size="xs"
                        variant="filled"
                        color={item.cacheState === 'failed' || item.cacheState === 'paused' ? 'red' : item.cacheState === 'ready' ? 'teal' : 'brand'}
                        pos="absolute"
                        bottom={isCaching ? 10 : 6}
                        left={6}
                        style={{ zIndex: 2, maxWidth: 'calc(100% - 12px)' }}
                      >
                        {badge}
                      </Badge>
                    )}

                    {isRefreshingItem && (
                      <Box
                        pos="absolute"
                        inset={0}
                        style={{
                          zIndex: 4,
                          display: 'flex',
                          flexDirection: 'column',
                          alignItems: 'center',
                          justifyContent: 'center',
                          gap: 6,
                          background: 'color-mix(in srgb, var(--surface) 82%, transparent)',
                        }}
                      >
                        <Loader size="sm" />
                        <Text size="xs" fw={600}>
                          {refreshItemStatus?.state === 'running'
                            ? t('shelf.refreshingBook', '正在刷新目录')
                            : t('shelf.refreshQueued', '等待刷新')}
                        </Text>
                      </Box>
                    )}

                    {isCaching && (
                      <Progress
                        value={percent}
                        size={4}
                        radius={0}
                        pos="absolute"
                        bottom={0}
                        left={0}
                        right={0}
                        style={{ zIndex: 3 }}
                      />
                    )}
                  </Box>

                  {/* Book Metadata */}
                  <Stack gap={4} mt="xs" style={{ flex: 1, minWidth: 0 }}>
                    <Text
                      fw={600}
                      size="sm"
                      lineClamp={1}
                      title={item.name}
                      style={{ cursor: 'pointer' }}
                      onClick={batchMode ? (e: React.MouseEvent) => { e.stopPropagation(); toggleSelectKey(itemKey) } : openItem}
                    >
                      {item.name}
                    </Text>
                    <Text size="xs" c="dimmed" lineClamp={1}>
                      {item.author || t('common.unknownAuthor', '未知作者')}
                    </Text>
                    {item.latestChapterTitle && (
                      <Text size="xs" c="dimmed" lineClamp={1} title={item.latestChapterTitle}>
                        {t('shelf.latestChapterWithTitle', '最新：{{title}}', { title: item.latestChapterTitle })}
                      </Text>
                    )}

                    {(item.cacheState === 'failed' || item.cacheState === 'paused') && (
                      <Button
                        size="compact-xs"
                        variant="light"
                        color="red"
                        fullWidth
                        justify="space-between"
                        leftSection={<Icon name="alert" size={12} />}
                        onClick={e => {
                          e.stopPropagation()
                          dispatchShelfModal({ type: 'openManage', item })
                        }}
                        title={item.cacheError || t('shelf.cacheFailed', '缓存中断')}
                      >
                        <Text size="xs" truncate>
                          {item.cacheError || t('shelf.cacheInterruptedNoReason', '缓存任务已中断')}
                        </Text>
                      </Button>
                    )}

                    <Group gap={4} wrap="wrap" mt="auto" pt={2}>
                      <Badge
                        size="xs"
                        variant="light"
                        color={item.isReadFinished ? 'teal' : item.isReading ? 'brand' : 'gray'}
                      >
                        {item.isReadFinished
                          ? t('shelf.statusRead', '已读')
                          : item.isReading
                            ? t('shelf.statusReading', '在读')
                            : item.isUnread
                              ? t('shelf.statusUnread', '未读')
                              : item.completed
                                ? t('shelf.completed', '已读完')
                                : item.chapterIndex === undefined
                                  ? t('shelf.justAdded', '刚加入书架')
                                  : t('shelf.chapterAt', '第 {{count}} 章', { count: item.chapterIndex + 1 })}
                        {readingTotal > 0 ? ` (${readingChapter}/${readingTotal})` : ''}
                      </Badge>

                      {item.groupName && (
                        <Badge size="xs" variant="outline" color="gray" title={item.groupName}>
                          {item.groupName}
                        </Badge>
                      )}
                      {item.canUpdate === false && !isLocalBook(item) && (
                        <Badge size="xs" variant="light" color="gray">{t('shelf.updatesPaused', '已停更')}</Badge>
                      )}
                      {item.updateError && (
                        <Badge size="xs" variant="light" color="red" title={t('shelf.lastRefreshFailed', '上次目录刷新失败，已保留原目录')}>
                          {t('shelf.refreshFailedShort', '更新失败')}
                        </Badge>
                      )}
                    </Group>
                    {item.updateError && !batchMode && canRefreshBook(item) && (
                      <Box mt={2}>{renderRefreshRetry(item)}</Box>
                    )}
                  </Stack>

                  {/* Card Footer */}
                  {!batchMode && (
                    <Group gap={6} mt="xs" wrap="nowrap">
                      <Button
                        size="xs"
                        variant="light"
                        style={{ flex: 1 }}
                        leftSection={<Icon name="book" size={14} />}
                        onClick={() => openItem()}
                      >
                        {t('shelf.continueReading', '继续阅读')}
                      </Button>
                      <Tooltip label={t('shelf.viewDetails', '查看书籍详情')}>
                        <ActionIcon
                          size="md"
                          variant="default"
                          onClick={() => setDetailItem(item)}
                          aria-label={t('shelf.viewDetails', '查看书籍详情')}
                        >
                          <Icon name="file" size={15} />
                        </ActionIcon>
                      </Tooltip>
                      <Tooltip label={t('shelf.moreActions', '更多操作: {{name}}', { name: item.name })}>
                        <ActionIcon
                          size="md"
                          variant="default"
                          onClick={() => dispatchShelfModal({ type: 'openManage', item })}
                          aria-label={t('shelf.moreActions', '更多操作: {{name}}', { name: item.name })}
                        >
                          <Icon name="more" size={15} />
                        </ActionIcon>
                      </Tooltip>
                    </Group>
                  )}
                </Card>
              )
            })}
          </SimpleGrid>
        )}
      </Stack>

      {/* Floating Batch Action Toolbar */}
      {batchMode && (
        <Paper
          p="sm"
          withBorder
          radius="lg"
          className="legado-batch-affix"
          role="toolbar"
          aria-label={t('shelf.batchToolbar', '批量操作栏')}
        >
          <Group justify="space-between" align="center" wrap="wrap" gap="sm">
            <Group gap="xs" wrap="nowrap">
              <Badge variant="filled" color="brand">
                {t('common.selectedBooks', '已选 {{count}} 本', { count: selectedKeys.size })}
              </Badge>
              <Button
                size="xs"
                variant="subtle"
                onClick={selectedKeys.size === visibleItems.length && visibleItems.length > 0 ? deselectAll : selectAllVisible}
              >
                {selectedKeys.size === visibleItems.length && visibleItems.length > 0
                  ? t('shelf.deselectAll', '取消全选')
                  : t('common.selectAllCurrent', '全选当前')}
              </Button>
            </Group>

            <Group gap={6} wrap="wrap">
              <Button
                size="xs"
                variant="default"
                loading={refreshRunning}
                disabled={selectedKeys.size === 0 || refreshRunning}
                leftSection={!refreshRunning ? <Icon name="refresh" size={13} /> : undefined}
                onClick={() => void refreshBooks(visibleItems.filter(item => selectedKeys.has(`${item.sourceId}\u0000${item.bookUrl}`)))}
              >
                {t('shelf.refreshSelected', '更新目录')}
              </Button>
              <Button
                size="xs"
                variant="default"
                disabled={selectedKeys.size === 0}
                leftSection={<Icon name="bookmark" size={13} />}
                onClick={() => setBatchMoving(true)}
              >
                {t('shelf.batchMoveGroup', '移动分组')}
              </Button>
              <Button
                size="xs"
                variant="default"
                disabled={selectedKeys.size === 0}
                leftSection={<Icon name="check" size={13} />}
                onClick={() => void handleBatchMarkCompleted(true)}
              >
                {t('shelf.markRead', '标为已读')}
              </Button>
              <Button
                size="xs"
                variant="default"
                disabled={selectedKeys.size === 0}
                leftSection={<Icon name="refresh" size={13} />}
                onClick={() => void handleBatchMarkCompleted(false)}
              >
                {t('shelf.markReading', '标为在读')}
              </Button>
              <Button
                size="xs"
                variant="default"
                disabled={selectedKeys.size === 0}
                leftSection={<Icon name="sliders" size={13} />}
                onClick={() => void handleBatchReclean()}
              >
                {t('shelf.batchClean', '重洗规则')}
              </Button>
              <Button
                size="xs"
                variant="light"
                color="red"
                disabled={selectedKeys.size === 0}
                leftSection={<Icon name="trash" size={13} />}
                onClick={() => void handleBatchDelete()}
              >
                {t('shelf.removeFromShelf', '移出书架')}
              </Button>
              <Button
                size="xs"
                onClick={() => {
                  setBatchMode(false)
                  setSelectedKeys(new Set())
                }}
              >
                {t('common.ok', '完成')}
              </Button>
            </Group>
          </Group>
        </Paper>
      )}

      {detailItem && (
        <ShelfBookDetailModal
          key={`${detailItem.sourceId}\u0000${detailItem.bookUrl}`}
          item={detailItem}
          source={sources.find(source => source.id === detailItem.sourceId)}
          onShelfChanged={() => void load()}
          onClose={() => setDetailItem(null)}
          onRead={() => {
            const target = detailItem
            setDetailItem(null)
            onOpenBook(target)
          }}
          onManage={() => {
            const target = detailItem
            setDetailItem(null)
            dispatchShelfModal({ type: 'openManage', item: target })
          }}
        />
      )}

      {/* Book Management Modal（一级）：只在 `manage` 层挂载。打开二级时它**不渲染**，
          但它在状态机里的 item 仍被保留 ⇒ 取消 / ESC / 点遮罩 / 清理执行完都能回到它 */}
      {managingItem && (
        <BookManageModal
          item={managingItem}
          groups={groups}
          onClose={() => dispatchShelfModal({ type: 'closeManage' })}
          onOpenDetail={() => {
            const target = managingItem
            dispatchShelfModal({ type: 'closeManage' })
            setDetailItem(target)
          }}
          onExport={() => {
            const target = managingItem
            dispatchShelfModal({ type: 'closeManage' })
            setExportingItem(target)
          }}
          onSwitchSource={() => {
            const target = managingItem
            dispatchShelfModal({ type: 'closeManage' })
            setSwitchingItem(target)
          }}
          onCache={chapterConcurrency => cache(managingItem, chapterConcurrency)}
          onCancelCache={() => {
            void cancelCache(managingItem)
            dispatchShelfModal({ type: 'updateItem', item: { ...managingItem, cacheState: 'failed', cacheError: t('shelf.cacheErrorCancelled', '已取消缓存') } })
          }}
          onSetCanUpdate={canUpdate => setCanUpdate(managingItem, canUpdate)}
          updateSettingBusy={updatingRefreshSettingKey === `${managingItem.sourceId}\u0000${managingItem.bookUrl}`}
          onToggleCompleted={() => setCompleted(managingItem, !managingItem.completed)}
          onUpdateInfo={updated => {
            setItems(values => values.map(v => v.sourceId === updated.sourceId && v.bookUrl === updated.bookUrl ? updated : v))
            dispatchShelfModal({ type: 'updateItem', item: updated })
            void load()
          }}
          // issue #66：这里**只叠加二级**，绝不关闭一级 —— 一级是哪本书由状态机保留，
          // 二级「取消」才能回到「书籍管理」（文案承诺的行为）。
          onClearCache={() => dispatchShelfModal({ type: 'openClearCacheScope' })}
          onRemove={() => remove(managingItem)}
        />
      )}

      {/* 「清除缓存」范围选择弹窗（二级）：与一级**互斥**挂载（同一时刻只渲染一层，不是嵌在
          一级的 modal-backdrop 里），且自带 portal。取消 / ESC / 点遮罩 / 执行完都只退一级 */}
      {clearingCacheItem && (
        <ClearCacheScopeModal
          item={clearingCacheItem}
          theme={theme}
          busy={clearingCache}
          busyScope={clearingScope}
          onClose={() => dispatchShelfModal({ type: 'closeClearCacheScope' })}
          onPick={scope => void clearCache(clearingCacheItem, scope)}
        />
      )}

      {/* Standalone Source Switch Modal for Shelf Book */}
      {switchingItem && (
        <SourceSwitchModal
          bookName={switchingItem.name}
          author={switchingItem.author}
          currentSourceId={switchingItem.sourceId}
          currentBookUrl={switchingItem.bookUrl}
          currentChapterIndex={switchingItem.chapterIndex}
          knownAlternateSources={switchingItem.alternateSources}
          onSwitch={handleSwitchShelfSource}
          onClose={() => setSwitchingItem(null)}
        />
      )}

      {exportingItem && (
        <BookExportModal item={exportingItem} onClose={() => setExportingItem(null)} />
      )}

      {/* Group Management Modal */}
      {managingGroups && (
        <GroupManageModal
          groups={groups}
          onClose={() => setManagingGroups(false)}
          onGroupsChanged={load}
        />
      )}

      {/* Batch Move Group Modal */}
      {batchMoving && (
        <BatchMoveGroupModal
          groups={groups}
          selectedCount={selectedKeys.size}
          onClose={() => setBatchMoving(false)}
          onSelectGroup={handleBatchMoveGroup}
        />
      )}
    </Box>
  )
}
