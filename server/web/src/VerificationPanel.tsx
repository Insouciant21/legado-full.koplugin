import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  api,
  ApiRequestError,
  type SourceVerificationInteraction,
  type SourceVerificationSession,
} from './api'
import { Icon } from './icons'
import { ButtonSpinner } from './ButtonSpinner'

/**
 * 全局书源人工验证面板。
 *
 * 背景：书源 JS 里的 `java.startBrowserAwait(url)` / `getVerificationCode()` 会挂起原脚本，
 * 等服务端建立一个**人工**浏览器会话（mode = manual）。搜索/登录请求在等这个会话时必须
 * 仍能看到并操作它，所以面板挂在 App shell 上、所有页面可见。
 *
 * 硬性约束：
 * - 只展示 `mode === 'manual'` 的会话；自动 webView 抓取（mode = auto）不得弹验证码面板。
 * - 不用标题文案判断验证码：读 DTO 的 `kind === 'captcha'`。
 * - 优先使用 CDP JPEG 实时流；WebSocket 不可用时自动降级为 no-store 截图。
 * - 没有待处理会话时不渲染任何浮层按钮。
 */

export const ACTIVE_VERIFICATION_STATES = ['queued', 'loading', 'interactive', 'evaluating'] as const

/** 会话是否仍处于“等待用户/服务端处理”的活跃状态。 */
export const isActiveVerification = (session: SourceVerificationSession) =>
  (ACTIVE_VERIFICATION_STATES as readonly string[]).includes(session.state)

/** 只有 `mode === 'manual'` 的人工会话才允许进入全局验证面板；自动抓取不得弹验证码。 */
export const isManualVerification = (session: SourceVerificationSession) => session.mode === 'manual'

export const filterManualVerifications = (sessions: SourceVerificationSession[]) =>
  sessions.filter(isManualVerification)

const REMOTE_KEYS = new Set([
  'Enter', 'Tab', 'Backspace', 'Delete', 'Escape',
  'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
  'Home', 'End', 'PageUp', 'PageDown',
])

const SCREENSHOT_ZOOM_LEVELS = [1, 1.25, 1.5, 1.75, 2] as const

const formatVerificationLocation = (value: string | undefined, inlineLabel: string) => {
  if (!value) return inlineLabel
  if (value.startsWith('data:')) return inlineLabel
  try {
    const url = new URL(value)
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return inlineLabel
    const path = url.pathname === '/' ? '' : url.pathname
    return `${url.host}${path}`
  } catch {
    return inlineLabel
  }
}

/**
 * 把一次点击（相对截图元素的 CSS 像素）换算成截图**自然像素**坐标。
 *
 * 后端 `mouse.click(x, y)` 需要的是截图真实像素；面板里图片是等比缩放的，
 * 因此必须用 naturalWidth/rect.width 的比值换算，否则在窄屏/缩放下点空。
 * 任何非法尺寸返回 null（调用方应忽略这次点击，而不是发出错误坐标）。
 */
export function screenshotClickToPixel(
  clickX: number,
  clickY: number,
  rect: { left: number; top: number; width: number; height: number },
  natural: { width: number; height: number },
): { x: number; y: number } | null {
  if (rect.width <= 0 || rect.height <= 0 || natural.width <= 0 || natural.height <= 0) return null
  const x = (clickX - rect.left) * (natural.width / rect.width)
  const y = (clickY - rect.top) * (natural.height / rect.height)
  return { x: Math.round(x * 100) / 100, y: Math.round(y * 100) / 100 }
}

type ScreenshotState = {
  sessionId: string
  url: string
  width: number
  height: number
  loading: boolean
  error: string
}

type ResultSummary = { status: number; bytes: number } | { error: string } | null
type StreamStatus = 'fallback' | 'connecting' | 'live'

type StreamMessage = {
  type: 'ready' | 'state' | 'error' | 'closed'
  state?: string
  url?: string
  title?: string
  error?: string | null
  width?: number
  height?: number
}

export function VerificationPanel() {
  const { t } = useTranslation()
  const [sessions, setSessions] = useState<SourceVerificationSession[]>([])
  const [open, setOpen] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [shot, setShot] = useState<ScreenshotState | null>(null)
  const [shotSeq, setShotSeq] = useState(0)
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState('')
  const [textInput, setTextInput] = useState('')
  const [keyInput, setKeyInput] = useState('Enter')
  const [captchaInput, setCaptchaInput] = useState('')
  const [zoom, setZoom] = useState(1)
  const [browserFocused, setBrowserFocused] = useState(false)
  const [streamStatus, setStreamStatus] = useState<StreamStatus>('fallback')
  const [streamAttempt, setStreamAttempt] = useState(0)
  const [results, setResults] = useState<Record<string, ResultSummary>>({})
  const shotUrlRef = useRef<string | null>(null)
  const sawPendingRef = useRef(false)
  const browserViewRef = useRef<HTMLDivElement | null>(null)
  const interactionQueueRef = useRef<Promise<void>>(Promise.resolve())
  const interactionPendingRef = useRef(0)
  const directTypeBufferRef = useRef('')
  const directTypeTimerRef = useRef<number | null>(null)
  const wheelDeltaRef = useRef(0)
  const wheelTimerRef = useRef<number | null>(null)
  const streamRef = useRef<WebSocket | null>(null)
  const streamFrameSizeRef = useRef({ width: 1072, height: 1448 })

  const manualSessions = useMemo(() => filterManualVerifications(sessions), [sessions])
  const activeSessions = useMemo(() => manualSessions.filter(isActiveVerification), [manualSessions])
  const selected = useMemo(
    () =>
      manualSessions.find(session => session.id === selectedId && isActiveVerification(session))
      ?? activeSessions[0]
      ?? manualSessions.find(session => session.id === selectedId)
      ?? manualSessions[0]
      ?? null,
    [manualSessions, selectedId, activeSessions],
  )

  const revokeShotUrl = useCallback(() => {
    if (shotUrlRef.current) {
      URL.revokeObjectURL(shotUrlRef.current)
      shotUrlRef.current = null
    }
  }, [])

  useEffect(() => revokeShotUrl, [revokeShotUrl])

  // 切换会话时重置截图缩放、远程焦点和尚未发送的键盘/滚轮缓冲。
  useEffect(() => {
    setZoom(1)
    setBrowserFocused(false)
    directTypeBufferRef.current = ''
    wheelDeltaRef.current = 0
    if (directTypeTimerRef.current !== null) {
      window.clearTimeout(directTypeTimerRef.current)
      directTypeTimerRef.current = null
    }
    if (wheelTimerRef.current !== null) {
      window.clearTimeout(wheelTimerRef.current)
      wheelTimerRef.current = null
    }
  }, [selected?.id])

  useEffect(() => () => {
    if (directTypeTimerRef.current !== null) window.clearTimeout(directTypeTimerRef.current)
    if (wheelTimerRef.current !== null) window.clearTimeout(wheelTimerRef.current)
  }, [])

  // CDP 实时流是主通道；连接失败或关闭后保留截图 fallback，并低频尝试重连。
  useEffect(() => {
    setStreamStatus('fallback')
    if (!open || !selected || selected.state !== 'interactive') return

    let stopped = false
    let retryTimer: number | null = null
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const socket = new WebSocket(`${protocol}//${window.location.host}${api.verificationStreamUrl(selected.sourceId, selected.id)}`)
    socket.binaryType = 'arraybuffer'
    streamRef.current = socket
    setStreamStatus('connecting')

    const updateFromMessage = (message: StreamMessage) => {
      if (stopped) return
      if (message.type === 'ready') setStreamStatus('live')
      if (Number.isFinite(message.width) && Number.isFinite(message.height)) {
        streamFrameSizeRef.current = {
          width: Math.max(1, Number(message.width)),
          height: Math.max(1, Number(message.height)),
        }
      }
      if (message.type === 'error' && message.error) {
        setActionError(message.error)
        return
      }
      if (message.type === 'closed') setStreamStatus('fallback')
      setSessions(prev => prev.map(item => {
        if (item.id !== selected.id) return item
        return {
          ...item,
          state: message.state ?? item.state,
          url: message.url ?? item.url,
          title: message.title ?? item.title,
          error: message.error ?? item.error,
        }
      }))
    }

    socket.onmessage = event => {
      if (stopped) return
      if (typeof event.data === 'string') {
        const message = (() => {
          try { return JSON.parse(event.data) as StreamMessage } catch { return null }
        })()
        if (message) updateFromMessage(message)
        return
      }
      const blob = new Blob([event.data], { type: 'image/jpeg' })
      const url = URL.createObjectURL(blob)
      setStreamStatus('live')
      revokeShotUrl()
      shotUrlRef.current = url
      setShot({
        sessionId: selected.id,
        url,
        width: streamFrameSizeRef.current.width,
        height: streamFrameSizeRef.current.height,
        loading: false,
        error: '',
      })
    }
    socket.onopen = () => {
      if (!stopped) setActionError('')
    }
    socket.onerror = () => {
      // 交给 close 事件统一切到 fallback，确保关闭后截图 effect 能看到 CLOSED 状态。
      if (!stopped) socket.close()
    }
    socket.onclose = () => {
      if (stopped) return
      setStreamStatus('fallback')
      retryTimer = window.setTimeout(() => setStreamAttempt(value => value + 1), 1800)
    }

    return () => {
      stopped = true
      if (retryTimer !== null) window.clearTimeout(retryTimer)
      if (streamRef.current === socket) streamRef.current = null
      socket.close()
    }
  }, [open, selected?.id, selected?.state, streamAttempt, revokeShotUrl, t])

  // 全局轮询：人工会话可能在任意请求（搜索、登录动作）里产生，面板必须自行发现。
  useEffect(() => {
    let cancelled = false
    const tick = async () => {
      try {
        const list = await api.verifications()
        if (cancelled) return
        setSessions(filterManualVerifications(list))
      } catch {
        // 面板不是网络错误汇报器：轮询失败保留上一次结果，不打断用户。
      }
    }
    void tick()
    const timer = setInterval(() => void tick(), 2500)
    return () => {
      cancelled = true
      clearInterval(timer)
    }
  }, [])

  // 出现新的待处理会话时自动展开一次（没有待处理会话时绝不弹）。
  useEffect(() => {
    if (activeSessions.length > 0 && !sawPendingRef.current) {
      sawPendingRef.current = true
      setOpen(true)
    }
    if (activeSessions.length === 0) sawPendingRef.current = false
  }, [activeSessions.length])

  // 全部处理完后自动收起，避免留下一个没有内容的浮层。
  useEffect(() => {
    if (!open || activeSessions.length > 0) return
    const timer = setTimeout(() => setOpen(false), 5000)
    return () => clearTimeout(timer)
  }, [open, activeSessions.length])

  // 会话被服务端清理后，清空选中项。
  useEffect(() => {
    if (selectedId && !manualSessions.some(session => session.id === selectedId)) setSelectedId(null)
  }, [manualSessions, selectedId])

  // 拉取截图：每次都是 no-store 的新请求，成功后再生成 blob URL。
  useEffect(() => {
    if (!open || !selected || streamStatus === 'live') return
    const streamSocket = streamRef.current
    if (
      selected.state === 'interactive'
      && streamSocket
      && streamSocket.readyState !== WebSocket.CLOSED
    ) return
    let cancelled = false
    setShot(prev => (prev?.sessionId === selected.id
      ? { ...prev, loading: true, error: '' }
      : { sessionId: selected.id, url: '', width: 0, height: 0, loading: true, error: '' }))
    void api.verificationScreenshot(selected.sourceId, selected.id)
      .then(blob => {
        if (cancelled) return
        const url = URL.createObjectURL(blob)
        const image = new Image()
        image.onload = () => {
          if (cancelled) {
            URL.revokeObjectURL(url)
            return
          }
          revokeShotUrl()
          shotUrlRef.current = url
          setShot({ sessionId: selected.id, url, width: image.naturalWidth, height: image.naturalHeight, loading: false, error: '' })
        }
        image.onerror = () => {
          URL.revokeObjectURL(url)
          if (!cancelled) setShot({ sessionId: selected.id, url: '', width: 0, height: 0, loading: false, error: t('verification.screenshotFailed', '截图加载失败') })
        }
        image.src = url
      })
      .catch((error: unknown) => {
        if (cancelled) return
        setShot({
          sessionId: selected.id,
          url: '',
          width: 0,
          height: 0,
          loading: false,
          error: error instanceof Error ? error.message : t('verification.screenshotFailed', '截图加载失败'),
        })
      })
    return () => {
      cancelled = true
    }
  }, [open, selected?.id, shotSeq, streamStatus, revokeShotUrl, t])

  // 会话加载中或首张截图暂时返回「页面尚未就绪」时自动重试；成功后不持续截图占用浏览器线程。
  useEffect(() => {
    if (!open || !selected || streamStatus === 'live' || !isActiveVerification(selected)) return
    const streamSocket = streamRef.current
    if (
      selected.state === 'interactive'
      && streamSocket
      && streamSocket.readyState !== WebSocket.CLOSED
    ) return
    const retryFailedInteractiveShot = selected.state === 'interactive' && Boolean(shot?.error)
    if (selected.state === 'interactive' && !retryFailedInteractiveShot) return
    const delay = selected.state === 'interactive' ? 1200 : 2600
    const timer = setInterval(() => setShotSeq(value => value + 1), delay)
    return () => clearInterval(timer)
  }, [open, selected?.id, selected?.state, shot?.error, streamStatus])

  // 已完成会话拉一次结果元数据（只显示状态码与字节数，不渲染正文）。
  useEffect(() => {
    if (!selected || selected.state !== 'completed' || results[selected.id] !== undefined) return
    let cancelled = false
    void api.verificationResult(selected.sourceId, selected.id)
      .then(result => {
        if (cancelled) return
        setResults(prev => ({ ...prev, [selected.id]: result ? { status: result.status, bytes: result.body.length } : null }))
      })
      .catch((error: unknown) => {
        if (cancelled) return
        setResults(prev => ({ ...prev, [selected.id]: { error: error instanceof Error ? error.message : t('verification.actionFailed', '操作失败') } }))
      })
    return () => {
      cancelled = true
    }
  }, [selected?.id, selected?.state, results, t])

  /**
   * 浏览器操作严格串行执行。直接键盘输入、滚轮和工具栏可能在同一瞬间触发，
   * 如果并发提交，`type("ab") + Backspace` 会因网络乱序变成不可预测的结果。
   */
  const runInteraction = (interaction: SourceVerificationInteraction): Promise<void> => {
    if (!selected) return Promise.resolve()
    const stream = streamRef.current
    if (streamStatus === 'live' && stream?.readyState === WebSocket.OPEN && stream.bufferedAmount < 256 * 1024) {
      try {
        stream.send(JSON.stringify(interaction))
        setActionError('')
        return Promise.resolve()
      } catch {
        // 立即降级到 REST；WebSocket 的 close 事件随后会触发截图重连。
        setStreamStatus('fallback')
      }
    }
    const sourceId = selected.sourceId
    const sessionId = selected.id
    const task = interactionQueueRef.current.then(async () => {
      interactionPendingRef.current += 1
      setBusy(true)
      setActionError('')
      try {
        await api.verificationInteract(sourceId, sessionId, interaction)
        setShotSeq(value => value + 1)
        if (interaction.action !== 'type' && interaction.action !== 'scroll' && interaction.action !== 'key') {
          const next = await api.verification(sourceId, sessionId)
          setSessions(prev => prev.map(item => item.id === next.id ? next : item))
        }
      } catch (error) {
        setActionError(error instanceof Error ? error.message : t('verification.actionFailed', '操作失败'))
      } finally {
        interactionPendingRef.current = Math.max(0, interactionPendingRef.current - 1)
        if (interactionPendingRef.current === 0) setBusy(false)
      }
    })
    interactionQueueRef.current = task.catch(() => undefined)
    return task
  }

  const flushDirectType = () => {
    if (directTypeTimerRef.current !== null) {
      window.clearTimeout(directTypeTimerRef.current)
      directTypeTimerRef.current = null
    }
    const text = directTypeBufferRef.current
    directTypeBufferRef.current = ''
    if (text) void runInteraction({ action: 'type', text })
  }

  const scheduleDirectType = (text: string) => {
    directTypeBufferRef.current += text
    if (directTypeTimerRef.current !== null) window.clearTimeout(directTypeTimerRef.current)
    directTypeTimerRef.current = window.setTimeout(flushDirectType, 120)
  }

  const handleScreenshotKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (!selected || selected.state !== 'interactive' || (busy && interactionPendingRef.current === 0) || event.nativeEvent.isComposing) return
    if (event.ctrlKey || event.metaKey || event.altKey) return
    if (event.key.length === 1) {
      event.preventDefault()
      scheduleDirectType(event.key)
      return
    }
    if (!REMOTE_KEYS.has(event.key)) return
    event.preventDefault()
    flushDirectType()
    void runInteraction({ action: 'key', key: event.key })
  }

  const handleScreenshotWheel = (event: React.WheelEvent<HTMLDivElement>) => {
    // 放大截图时滚轮用于查看大图；适应窗口时滚轮直接滚动远端网页。
    if (zoom > 1 || !selected || selected.state !== 'interactive' || (busy && interactionPendingRef.current === 0)) return
    event.preventDefault()
    wheelDeltaRef.current += event.deltaY
    if (wheelTimerRef.current !== null) return
    wheelTimerRef.current = window.setTimeout(() => {
      wheelTimerRef.current = null
      const delta = Math.max(-1200, Math.min(1200, wheelDeltaRef.current))
      wheelDeltaRef.current = 0
      if (Math.abs(delta) >= 1) void runInteraction({ action: 'scroll', x: 0, y: delta })
    }, 100)
  }

  const handleScreenshotClick = (event: React.MouseEvent<HTMLImageElement>) => {
    if (!selected || selected.kind === 'captcha' || selected.state !== 'interactive' || busy) return
    const image = event.currentTarget
    browserViewRef.current?.focus()
    setBrowserFocused(true)
    // 显示尺寸 → 截图像素：后端 mouse.click 需要的是截图真实像素坐标。
    const point = screenshotClickToPixel(
      event.clientX,
      event.clientY,
      image.getBoundingClientRect(),
      { width: image.naturalWidth, height: image.naturalHeight },
    )
    if (!point) return
    void runInteraction({ action: 'click', ...point })
  }

  /**
   * complete/cancel 只提交结束请求，Chromium 还要生成最终 body、落库 Cookie 并恢复原书源脚本。
   * 在会话真正离开活跃态前保持按钮忙碌，避免重复完成或取消。
   */
  const waitForSessionToSettle = useCallback(async (session: SourceVerificationSession) => {
    const deadline = Date.now() + 12_000
    while (Date.now() < deadline) {
      try {
        const next = await api.verification(session.sourceId, session.id)
        setSessions(prev => prev.map(item => item.id === next.id ? next : item))
        if (!isActiveVerification(next)) return next
      } catch (error) {
        if (error instanceof ApiRequestError && error.status === 404) return null
      }
      await new Promise(resolve => setTimeout(resolve, 300))
    }
    return null
  }, [])

  const handleComplete = async () => {
    if (!selected) return
    const captcha = selected.kind === 'captcha'
    if (captcha && !captchaInput.trim()) return
    setBusy(true)
    setActionError('')
    try {
      await api.verificationComplete(selected.sourceId, selected.id, captcha ? captchaInput.trim() : undefined)
      await waitForSessionToSettle(selected)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : t('verification.actionFailed', '操作失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleCancel = async () => {
    if (!selected) return
    setBusy(true)
    setActionError('')
    try {
      await api.verificationCancel(selected.sourceId, selected.id)
      await waitForSessionToSettle(selected)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : t('verification.actionFailed', '操作失败'))
    } finally {
      setBusy(false)
    }
  }

  if (activeSessions.length === 0 && !open) return null

  const stateLabel = (session: SourceVerificationSession) => {
    if (session.state === 'queued') return t('verification.stateQueued', '排队中')
    if (session.state === 'loading' || session.state === 'evaluating') return t('verification.stateLoading', '加载中')
    if (session.state === 'interactive') return t('verification.stateInteractive', '等待操作')
    if (session.state === 'completed') return t('verification.stateCompleted', '已完成')
    if (session.state === 'canceled') return t('verification.stateCanceled', '已取消')
    return t('verification.stateError', '失败')
  }

  const resultSummary = selected ? results[selected.id] : undefined
  const canInteract = Boolean(selected && selected.state === 'interactive' && !busy)
  const selectedTitle = selected?.title?.trim() || t('verification.title', '书源验证')
  const locationLabel = formatVerificationLocation(
    selected?.url,
    t('verification.inlinePage', '书源内置页面'),
  )
  const zoomIndex = SCREENSHOT_ZOOM_LEVELS.indexOf(zoom as typeof SCREENSHOT_ZOOM_LEVELS[number])
  const changeZoom = (direction: -1 | 1) => {
    const current = zoomIndex < 0 ? 0 : zoomIndex
    const next = Math.max(0, Math.min(SCREENSHOT_ZOOM_LEVELS.length - 1, current + direction))
    setZoom(SCREENSHOT_ZOOM_LEVELS[next])
  }

  return (
    <>
      {activeSessions.length > 0 && (
        <button type="button" className="verification-fab" onClick={() => setOpen(value => !value)} aria-expanded={open}>
          <Icon name="activity" />
          <span>{t('verification.badge', { count: activeSessions.length, defaultValue: `待处理 ${activeSessions.length} 个` })}</span>
        </button>
      )}
      {open && selected && (
        <div className="verification-overlay" role="dialog" aria-modal="true" aria-label={selectedTitle}>
          <div className="verification-panel">
            <header className="verification-panel-header">
              <div className="verification-title-block">
                <strong>{selectedTitle}</strong>
                <div className="verification-title-meta">
                  <span className={`verification-state ${isActiveVerification(selected) ? 'is-active' : ''}`}>{stateLabel(selected)}</span>
                  <small>{t('verification.badge', { count: activeSessions.length, defaultValue: `待处理 ${activeSessions.length} 个` })}</small>
                </div>
              </div>
              <button type="button" className="subtle-button" onClick={() => setOpen(false)} aria-label={t('verification.close', '关闭')}>
                <Icon name="close" />
              </button>
            </header>

            {manualSessions.length > 1 && (
              <div className="verification-session-list">
                {manualSessions.map(session => (
                  <button
                    type="button"
                    key={session.id}
                    className={`verification-session-item ${session.id === selected.id ? 'active' : ''}`}
                    onClick={() => setSelectedId(session.id)}
                  >
                    <span className="verification-session-title">{session.title || t('verification.title', '书源验证')}</span>
                    <small>{session.sourceId}</small>
                    <span className={`verification-state ${isActiveVerification(session) ? 'is-active' : ''}`}>{stateLabel(session)}</span>
                  </button>
                ))}
              </div>
            )}

            <div className="verification-panel-body">
              <section className="verification-browser">
                <div className="verification-browser-toolbar">
                  <div className="verification-browser-nav">
                    <button
                      type="button"
                      className="verification-tool-button"
                      title={t('verification.back', '返回上一页')}
                      disabled={!canInteract}
                      onClick={() => void runInteraction({ action: 'back' })}
                    >
                      <Icon name="arrowLeft" />
                    </button>
                    <button
                      type="button"
                      className="verification-tool-button"
                      title={t('verification.forward', '前进')}
                      disabled={!canInteract}
                      onClick={() => void runInteraction({ action: 'forward' })}
                    >
                      <Icon name="arrowRight" />
                    </button>
                    <button
                      type="button"
                      className="verification-tool-button"
                      title={t('verification.reload', '重新加载网页')}
                      disabled={!canInteract}
                      onClick={() => void runInteraction({ action: 'reload' })}
                    >
                      <Icon name="refresh" />
                    </button>
                  </div>
                  <div className="verification-location" title={selected.url}>
                    <span className="verification-location-dot" />
                    <span>{locationLabel}</span>
                  </div>
                  <div className="verification-zoom" aria-label={t('verification.zoom', '截图缩放')}>
                    <button type="button" className="verification-tool-button" disabled={zoomIndex <= 0} onClick={() => changeZoom(-1)}>−</button>
                    <span>{Math.round(zoom * 100)}%</span>
                    <button type="button" className="verification-tool-button" disabled={zoomIndex >= SCREENSHOT_ZOOM_LEVELS.length - 1} onClick={() => changeZoom(1)}>+</button>
                  </div>
                  {streamStatus === 'live' ? (
                    <span className="verification-live"><i />{t('verification.live', '实时')}</span>
                  ) : streamStatus === 'connecting' ? (
                    <span className="verification-stream-connecting"><ButtonSpinner size={12} />{t('verification.connecting', '连接中')}</span>
                  ) : (
                    <button
                      type="button"
                      className="verification-tool-button with-label"
                      title={t('verification.refreshScreenshot', '刷新截图')}
                      onClick={() => setShotSeq(value => value + 1)}
                    >
                      <Icon name="activity" />
                      <span>{t('verification.refreshFrame', '刷新画面')}</span>
                    </button>
                  )}
                </div>

                <div
                  ref={browserViewRef}
                  className={`verification-shot ${browserFocused ? 'is-focused' : ''} ${zoom > 1 ? 'is-zoomed' : ''}`}
                  tabIndex={selected.state === 'interactive' ? 0 : -1}
                  onKeyDown={handleScreenshotKeyDown}
                  onWheel={handleScreenshotWheel}
                >
                  {shot?.loading && (
                    <p className="verification-shot-status verification-shot-loading">
                      <ButtonSpinner size={14} />
                      {t('verification.screenshotLoading', '正在加载截图…')}
                    </p>
                  )}
                  {shot?.error && <p className="form-error verification-error">{shot.error}</p>}
                  {shot && shot.url && (
                    // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
                    <img
                      src={shot.url}
                      alt={selectedTitle}
                      className={`verification-shot-image ${selected.kind === 'captcha' || selected.state !== 'interactive' ? 'is-static' : ''}`}
                      style={zoom > 1 && shot.width > 0 ? { width: `${Math.round(shot.width * zoom)}px` } : undefined}
                      onClick={handleScreenshotClick}
                      draggable={false}
                    />
                  )}
                  {shot && shot.url && selected.kind !== 'captcha' && selected.state === 'interactive' && (
                    <p className="verification-hint">
                      {zoom > 1
                        ? t('verification.zoomedHint', '当前为放大查看；滚轮浏览大图，点按仍会操作网页')
                        : t('verification.clickHint', '点按页面即可操作；滚轮可滚动网页，键盘可输入到已聚焦控件')}
                    </p>
                  )}
                </div>
              </section>

              <aside className="verification-side">
                <div className="verification-meta">
                  <span className="verification-source">{selected.sourceId}</span>
                  {selected.kind === 'captcha' && <span className="verification-kind">{t('verification.captchaLabel', '验证码')}</span>}
                </div>
                {selected.error && <p className="form-error verification-error">{selected.error}</p>}
                {actionError && <p className="form-error verification-error">{actionError}</p>}

                {selected.state === 'completed' && resultSummary && (
                  <p className="verification-result">
                    {'status' in resultSummary
                      ? t('verification.resultMeta', { status: resultSummary.status, bytes: resultSummary.bytes, defaultValue: `HTTP ${resultSummary.status} · ${resultSummary.bytes} 字节` })
                      : t('verification.resultPending', '结果尚未就绪')}
                  </p>
                )}

                {selected.kind === 'captcha' ? (
                  <section className="verification-control-card">
                    <label className="verification-field">
                      <span>{t('verification.captchaLabel', '验证码')}</span>
                      <input
                        type="text"
                        value={captchaInput}
                        onChange={event => setCaptchaInput(event.target.value)}
                        placeholder={t('verification.captchaLabel', '验证码')}
                        disabled={!canInteract}
                        autoComplete="off"
                      />
                    </label>
                  </section>
                ) : (
                  <>
                    <section className="verification-control-card">
                      <strong>{t('verification.sendTextTitle', '输入到网页')}</strong>
                      <small>{t('verification.sendTextHint', '先点按网页里的输入框，再输入或粘贴文字。')}</small>
                      <div className="verification-send-row">
                        <input
                          type="text"
                          value={textInput}
                          onChange={event => setTextInput(event.target.value)}
                          onFocus={() => setBrowserFocused(false)}
                          onKeyDown={event => {
                            if (event.key === 'Enter' && textInput.length > 0 && canInteract) {
                              event.preventDefault()
                              void runInteraction({ action: 'type', text: textInput })
                            }
                          }}
                          placeholder={t('verification.textPlaceholder', '用户名、密码或要粘贴的内容')}
                          disabled={!canInteract}
                          autoComplete="off"
                        />
                        <button
                          type="button"
                          className="primary-button"
                          disabled={!canInteract || textInput.length === 0}
                          onClick={() => void runInteraction({ action: 'type', text: textInput })}
                        >
                          {t('verification.typeText', '输入文本')}
                        </button>
                      </div>
                    </section>

                    <section className="verification-control-card">
                      <strong>{t('verification.quickKeys', '快捷按键')}</strong>
                      <div className="verification-quick-keys">
                        {['Enter', 'Tab', 'Backspace', 'Escape'].map(key => (
                          <button
                            type="button"
                            key={key}
                            className="subtle-button"
                            disabled={!canInteract}
                            onClick={() => void runInteraction({ action: 'key', key })}
                          >
                            {key}
                          </button>
                        ))}
                      </div>
                    </section>

                    <section className="verification-control-card">
                      <strong>{t('verification.pageTools', '页面工具')}</strong>
                      <div className="verification-page-tools">
                        <button type="button" className="subtle-button" disabled={!canInteract} onClick={() => void runInteraction({ action: 'scroll', x: 0, y: -480 })}>
                          {t('verification.scrollUp', '向上滚动')}
                        </button>
                        <button type="button" className="subtle-button" disabled={!canInteract} onClick={() => void runInteraction({ action: 'scroll', x: 0, y: 480 })}>
                          {t('verification.scrollDown', '向下滚动')}
                        </button>
                      </div>
                      <details className="verification-advanced-keys">
                        <summary>{t('verification.otherKeys', '其他按键')}</summary>
                        <div className="verification-send-row">
                          <input
                            type="text"
                            value={keyInput}
                            onChange={event => setKeyInput(event.target.value)}
                            placeholder="Enter"
                            disabled={!canInteract}
                            autoComplete="off"
                          />
                          <button
                            type="button"
                            className="subtle-button"
                            disabled={!canInteract || keyInput.trim().length === 0}
                            onClick={() => void runInteraction({ action: 'key', key: keyInput.trim() })}
                          >
                            {t('verification.pressKey', '发送按键')}
                          </button>
                        </div>
                      </details>
                    </section>
                  </>
                )}
              </aside>
            </div>

            <footer className="verification-panel-footer">
              <span className={`verification-focus-hint ${browserFocused && canInteract ? 'is-ready' : ''}`}>
                {busy
                  ? t('verification.syncing', '正在同步页面…')
                  : browserFocused && canInteract
                    ? t('verification.keyboardReady', '页面已聚焦，可直接使用键盘输入')
                    : t('verification.focusHint', '点按页面即可操作；输入框内容可从右侧发送')}
              </span>
              <div className="verification-footer-actions">
                <button type="button" className="subtle-button" disabled={busy || !isActiveVerification(selected)} onClick={() => void handleCancel()}>
                  {t('verification.cancel', '关闭并取消')}
                </button>
                <button
                  type="button"
                  className="primary-button"
                  disabled={!canInteract || (selected.kind === 'captcha' && captchaInput.trim().length === 0)}
                  onClick={() => void handleComplete()}
                >
                  {busy && <ButtonSpinner size={14} />}
                  {selected.kind === 'captcha'
                    ? t('verification.completeCaptcha', '提交验证码')
                    : t('verification.completeBrowser', '完成并继续')}
                </button>
              </div>
            </footer>
          </div>
        </div>
      )}
    </>
  )
}
