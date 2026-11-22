import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Accordion,
  ActionIcon,
  Alert,
  Badge,
  Box,
  Button,
  Grid,
  Group,
  Loader,
  Modal,
  Paper,
  Stack,
  Tabs,
  Text,
  TextInput,
  Tooltip,
} from '@mantine/core'
import { useElementSize, useEventListener, useMergedRef } from '@mantine/hooks'
import { useTranslation } from 'react-i18next'
import {
  api,
  ApiRequestError,
  type SourceVerificationInteraction,
  type SourceVerificationSession,
} from './api'
import { Icon } from './icons'

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

const VIEWPORT_ZOOM_LEVELS = [1, 1.25, 1.5, 1.75, 2] as const
const MAX_REMOTE_VIEWPORT_EDGE = 1600
const WHEEL_LISTENER_OPTIONS = { passive: false }

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
  loading: boolean
  error: string
}

type FramePoint = { x: number; y: number; width: number; height: number; scale: number }

function pointOnFrame(image: HTMLImageElement | null, clientX: number, clientY: number): FramePoint | null {
  if (!image?.naturalWidth || !image.naturalHeight) return null
  const { naturalWidth: width, naturalHeight: height } = image
  const rect = image.getBoundingClientRect()
  const scale = Math.min(rect.width / width, rect.height / height)
  // During resize or reconnect object-fit can leave margins around the last frame.
  const painted = {
    left: rect.left + (rect.width - width * scale) / 2,
    top: rect.top + (rect.height - height * scale) / 2,
    width: width * scale,
    height: height * scale,
  }
  const point = screenshotClickToPixel(clientX, clientY, painted, { width, height })
  if (!point || point.x < 0 || point.y < 0 || point.x >= width || point.y >= height) return null
  return { ...point, width, height, scale }
}

type RemoteScroll = Extract<SourceVerificationInteraction, { action: 'scroll' }>
type QueuedScroll = {
  command: RemoteScroll
  send: (interaction: SourceVerificationInteraction) => Promise<void>
}
type TouchDrag = { id: number; origin: FramePoint; x: number; y: number; moved: boolean }

type ResultSummary = { status: number; bytes: number } | { error: string } | null
type StreamStatus = 'fallback' | 'connecting' | 'live'

type StreamMessage = {
  type: 'ready' | 'state' | 'error' | 'closed'
  state?: string
  url?: string
  title?: string
  error?: string | null
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
  const [streamStatus, setStreamStatus] = useState<StreamStatus>('fallback')
  const [streamAttempt, setStreamAttempt] = useState(0)
  const [results, setResults] = useState<Record<string, ResultSummary>>({})
  const shotUrlRef = useRef<string | null>(null)
  const sawPendingRef = useRef(false)
  const browserViewRef = useRef<HTMLDivElement | null>(null)
  const frameRef = useRef<HTMLImageElement | null>(null)
  const { ref: measureViewport, width: previewWidth, height: previewHeight } = useElementSize<HTMLDivElement>()
  const interactionQueueRef = useRef<Promise<void>>(Promise.resolve())
  const interactionPendingRef = useRef(0)
  const directTypeBufferRef = useRef('')
  const directTypeTimerRef = useRef<number | null>(null)
  const pendingScrollRef = useRef<QueuedScroll | null>(null)
  const scrollTimerRef = useRef<number | null>(null)
  const touchDragRef = useRef<TouchDrag | null>(null)
  const suppressDragClickRef = useRef(false)
  const streamRef = useRef<WebSocket | null>(null)

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
  const interactive = selected?.state === 'interactive'
  const interactivePage = interactive && selected.kind === 'page'
  const sessionId = selected?.id
  const sourceId = selected?.sourceId

  const revokeShotUrl = useCallback(() => {
    if (shotUrlRef.current) {
      URL.revokeObjectURL(shotUrlRef.current)
      shotUrlRef.current = null
    }
  }, [])

  useEffect(() => revokeShotUrl, [revokeShotUrl])

  useEffect(() => {
    setZoom(1)
  }, [selected?.id])

  // Abandon buffered input when the preview closes or the session changes.
  useEffect(() => () => {
    directTypeBufferRef.current = ''
    pendingScrollRef.current = null
    touchDragRef.current = null
    suppressDragClickRef.current = false
    if (directTypeTimerRef.current !== null) {
      window.clearTimeout(directTypeTimerRef.current)
      directTypeTimerRef.current = null
    }
    if (scrollTimerRef.current !== null) {
      window.clearTimeout(scrollTimerRef.current)
      scrollTimerRef.current = null
    }
  }, [open, selected?.id, selected?.state])

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
      : { sessionId: selected.id, url: '', loading: true, error: '' }))
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
          setShot({ sessionId: selected.id, url, loading: false, error: '' })
        }
        image.onerror = () => {
          URL.revokeObjectURL(url)
          if (!cancelled) setShot({ sessionId: selected.id, url: '', loading: false, error: t('verification.screenshotFailed', '截图加载失败') })
        }
        image.src = url
      })
      .catch((error: unknown) => {
        if (cancelled) return
        setShot({
          sessionId: selected.id,
          url: '',
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
  const runInteraction = useCallback((interaction: SourceVerificationInteraction): Promise<void> => {
    if (!sourceId || !sessionId) return Promise.resolve()
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
    const task = interactionQueueRef.current.then(async () => {
      interactionPendingRef.current += 1
      setBusy(true)
      setActionError('')
      try {
        await api.verificationInteract(sourceId, sessionId, interaction)
        setShotSeq(value => value + 1)
        if (interaction.action === 'back' || interaction.action === 'forward' || interaction.action === 'reload'
          || interaction.action === 'navigate' || interaction.action === 'click') {
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
  }, [sessionId, sourceId, streamStatus, t])

  // Keep the remote page at the same aspect ratio as the viewport. Zoom shrinks
  // the remote CSS viewport and lets Chromium lay out the page at that size.
  useEffect(() => {
    if (!open || !interactive || streamStatus === 'connecting' || !previewWidth || !previewHeight) return
    const scale = Math.max(zoom, previewWidth / MAX_REMOTE_VIEWPORT_EDGE, previewHeight / MAX_REMOTE_VIEWPORT_EDGE)
    const timer = window.setTimeout(() => {
      void runInteraction({
        action: 'resize',
        width: Math.max(1, Math.round(previewWidth / scale)),
        height: Math.max(1, Math.round(previewHeight / scale)),
      })
    }, 120)
    return () => window.clearTimeout(timer)
  }, [open, interactive, streamStatus, previewWidth, previewHeight, zoom, runInteraction])

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

  const flushScroll = useCallback(function flushScroll() {
    const pending = pendingScrollRef.current
    pendingScrollRef.current = null
    if (!pending) {
      scrollTimerRef.current = null
      return
    }
    const timer = scrollTimerRef.current
    const { command, send } = pending
    const finished = () => {
      if (scrollTimerRef.current !== timer) return
      scrollTimerRef.current = pendingScrollRef.current ? window.setTimeout(flushScroll, 32) : null
    }
    void send(command).then(finished, finished)
  }, [])

  // Coalesce wheel and touch deltas. Wait for the previous REST input before
  // sending more, so fast swipes cannot leave a backlog of screenshot requests.
  const queueScroll = useCallback((point: FramePoint, deltaX: number, deltaY: number) => {
    const { x, y, width, height, scale } = point
    const pending = pendingScrollRef.current
    const previous = pending?.send === runInteraction && pending.command.width === width && pending.command.height === height
      ? pending.command : undefined
    pendingScrollRef.current = {
      send: runInteraction,
      command: {
        action: 'scroll', x, y, width, height,
        deltaX: Math.max(-1200, Math.min(1200, (previous?.deltaX ?? 0) + deltaX / scale)),
        deltaY: Math.max(-1200, Math.min(1200, (previous?.deltaY ?? 0) + deltaY / scale)),
      },
    }
    if (scrollTimerRef.current === null) scrollTimerRef.current = window.setTimeout(flushScroll, 32)
  }, [flushScroll, runInteraction])

  const handleScreenshotWheel = useCallback((event: WheelEvent) => {
    if (!interactivePage || (busy && interactionPendingRef.current === 0) || event.ctrlKey || event.metaKey) return
    const point = pointOnFrame(frameRef.current, event.clientX, event.clientY)
    if (!point) return
    const { deltaMode, deltaX, deltaY } = event
    const shifted = event.shiftKey && deltaX === 0
    const view = browserViewRef.current
    const unit = deltaMode === WheelEvent.DOM_DELTA_LINE ? 16 : 1
    const unitX = deltaMode === WheelEvent.DOM_DELTA_PAGE ? (view?.clientWidth ?? 1) : unit
    const unitY = deltaMode === WheelEvent.DOM_DELTA_PAGE ? (view?.clientHeight ?? 1) : unit
    event.preventDefault()
    queueScroll(point, (shifted ? deltaY : deltaX) * unitX, (shifted ? 0 : deltaY) * unitY)
  }, [busy, interactivePage, queueScroll])
  const listenToWheel = useEventListener<'wheel', HTMLDivElement>('wheel', handleScreenshotWheel, WHEEL_LISTENER_OPTIONS)
  const viewportRef = useMergedRef(browserViewRef, measureViewport, listenToWheel)

  const handleTouchStart = (event: React.PointerEvent<HTMLImageElement>) => {
    if (!event.isPrimary) return
    suppressDragClickRef.current = false
    if (event.pointerType !== 'touch' || !interactivePage || busy) return
    const origin = pointOnFrame(event.currentTarget, event.clientX, event.clientY)
    if (!origin) return
    touchDragRef.current = { id: event.pointerId, origin, x: event.clientX, y: event.clientY, moved: false }
    event.currentTarget.setPointerCapture(event.pointerId)
  }

  const handleTouchMove = (event: React.PointerEvent<HTMLImageElement>) => {
    const drag = touchDragRef.current
    if (!drag || drag.id !== event.pointerId) return
    const dx = drag.x - event.clientX
    const dy = drag.y - event.clientY
    if (!drag.moved && Math.hypot(dx, dy) < 6) return
    drag.moved = true
    drag.x = event.clientX
    drag.y = event.clientY
    suppressDragClickRef.current = true
    queueScroll(drag.origin, dx, dy)
  }

  const handleTouchEnd = (event: React.PointerEvent<HTMLImageElement>) => {
    if (touchDragRef.current?.id === event.pointerId) touchDragRef.current = null
  }

  const handleScreenshotClick = (event: React.MouseEvent<HTMLImageElement>) => {
    if (suppressDragClickRef.current || !interactivePage || busy) return
    const point = pointOnFrame(event.currentTarget, event.clientX, event.clientY)
    if (!point) return
    browserViewRef.current?.focus({ preventScroll: true })
    const { x, y, width, height } = point
    void runInteraction({ action: 'click', x, y, width, height })
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
  const currentShot = shot?.sessionId === selected?.id ? shot : null
  const canInteract = Boolean(selected && selected.state === 'interactive' && !busy)
  const selectedTitle = selected?.title?.trim() || t('verification.title', '书源验证')
  const locationLabel = formatVerificationLocation(
    selected?.url,
    t('verification.inlinePage', '书源内置页面'),
  )
  const zoomIndex = VIEWPORT_ZOOM_LEVELS.indexOf(zoom as typeof VIEWPORT_ZOOM_LEVELS[number])
  const changeZoom = (direction: -1 | 1) => {
    const current = zoomIndex < 0 ? 0 : zoomIndex
    const next = Math.max(0, Math.min(VIEWPORT_ZOOM_LEVELS.length - 1, current + direction))
    setZoom(VIEWPORT_ZOOM_LEVELS[next])
  }

  return (
    <>
      {activeSessions.length > 0 && (
        <Button
          className="legado-verification-fab"
          color="gold"
          radius="xl"
          size="md"
          leftSection={<Icon name="activity" size={16} />}
          onClick={() => setOpen(value => !value)}
          aria-expanded={open}
        >
          {t('verification.badge', { count: activeSessions.length, defaultValue: `待处理 ${activeSessions.length} 个` })}
        </Button>
      )}
      {open && selected && (
        <Modal
          opened
          onClose={() => setOpen(false)}
          size="min(1120px, 96vw)"
          zIndex={400}
          withCloseButton={false}
          padding="md"
          aria-label={selectedTitle}
        >
          <Stack gap="sm">
            <Group justify="space-between" align="center" wrap="nowrap" pb="xs" style={{ borderBottom: '1px solid var(--line)' }}>
              <Group gap="sm" wrap="wrap" style={{ minWidth: 0 }}>
                <Text fw={700} size="md" truncate>{selectedTitle}</Text>
                <Badge
                  size="sm"
                  variant="light"
                  color={isActiveVerification(selected) ? 'brand' : selected.state === 'completed' ? 'teal' : 'gray'}
                >
                  {stateLabel(selected)}
                </Badge>
                <Text size="xs" c="dimmed">
                  {t('verification.badge', { count: activeSessions.length, defaultValue: `待处理 ${activeSessions.length} 个` })}
                </Text>
              </Group>
              <ActionIcon variant="subtle" color="gray" onClick={() => setOpen(false)} aria-label={t('verification.close', '关闭')}>
                <Icon name="close" size={16} />
              </ActionIcon>
            </Group>

            {manualSessions.length > 1 && (
              <Tabs value={selected.id} onChange={value => value && setSelectedId(value)} variant="outline">
                <Tabs.List style={{ overflowX: 'auto', flexWrap: 'nowrap' }}>
                  {manualSessions.map(session => (
                    <Tabs.Tab
                      key={session.id}
                      value={session.id}
                      rightSection={
                        <Badge size="xs" variant="light" color={isActiveVerification(session) ? 'brand' : 'gray'}>
                          {stateLabel(session)}
                        </Badge>
                      }
                    >
                      <Text size="xs" fw={600}>{session.title || session.sourceId}</Text>
                    </Tabs.Tab>
                  ))}
                </Tabs.List>
              </Tabs>
            )}

            <Grid gutter="md">
              <Grid.Col span={{ base: 12, md: 8 }}>
                <Paper withBorder radius="md" style={{ overflow: 'hidden' }}>
                  <Group
                    gap="xs"
                    px="xs"
                    py={6}
                    wrap="wrap"
                    style={{ borderBottom: '1px solid var(--line)', background: 'var(--sidebar-bg)' }}
                  >
                    <Group gap={4} wrap="nowrap">
                      <Tooltip label={t('verification.back', '返回上一页')}>
                        <ActionIcon size="sm" variant="subtle" color="gray" disabled={!canInteract} onClick={() => void runInteraction({ action: 'back' })} aria-label={t('verification.back', '返回上一页')}>
                          <Icon name="arrowLeft" size={14} />
                        </ActionIcon>
                      </Tooltip>
                      <Tooltip label={t('verification.forward', '前进')}>
                        <ActionIcon size="sm" variant="subtle" color="gray" disabled={!canInteract} onClick={() => void runInteraction({ action: 'forward' })} aria-label={t('verification.forward', '前进')}>
                          <Icon name="arrowRight" size={14} />
                        </ActionIcon>
                      </Tooltip>
                      <Tooltip label={t('verification.reload', '重新加载网页')}>
                        <ActionIcon size="sm" variant="subtle" color="gray" disabled={!canInteract} onClick={() => void runInteraction({ action: 'reload' })} aria-label={t('verification.reload', '重新加载网页')}>
                          <Icon name="refresh" size={14} />
                        </ActionIcon>
                      </Tooltip>
                    </Group>

                    <Paper px="xs" py={3} withBorder radius="sm" style={{ flex: '1 1 64px', minWidth: 0 }} title={selected.url}>
                      <Text size="xs" truncate style={{ fontFamily: 'var(--mantine-font-family-monospace)' }}>
                        {locationLabel}
                      </Text>
                    </Paper>

                    <Group gap={4} wrap="nowrap" aria-label={t('verification.zoom', '画面缩放')}>
                      <ActionIcon size="sm" variant="subtle" color="gray" disabled={!interactive || zoomIndex <= 0} onClick={() => changeZoom(-1)} aria-label={t('verification.zoomOut', '缩小画面')}>
                        -
                      </ActionIcon>
                      <Text size="xs" fw={600} miw={48} ta="center">{zoom === 1 ? t('verification.fitWidth', '适应宽度') : `${Math.round(zoom * 100)}%`}</Text>
                      <ActionIcon size="sm" variant="subtle" color="gray" disabled={!interactive || zoomIndex >= VIEWPORT_ZOOM_LEVELS.length - 1} onClick={() => changeZoom(1)} aria-label={t('verification.zoomIn', '放大画面')}>
                        +
                      </ActionIcon>
                    </Group>

                    {streamStatus === 'live' ? (
                      <Badge size="xs" variant="dot" color="teal">{t('verification.live', '实时')}</Badge>
                    ) : streamStatus === 'connecting' ? (
                      <Badge size="xs" variant="light" color="brand" leftSection={<Loader size={10} />}>
                        {t('verification.connecting', '连接中')}
                      </Badge>
                    ) : (
                      <Button
                        size="compact-xs"
                        variant="subtle"
                        leftSection={<Icon name="activity" size={13} />}
                        onClick={() => setShotSeq(value => value + 1)}
                      >
                        {t('verification.refreshFrame', '刷新画面')}
                      </Button>
                    )}
                  </Group>

                  <Box
                    h="min(58dvh, 520px)"
                    bg="var(--canvas)"
                    ref={viewportRef}
                    className="legado-verification-viewport"
                    role="region"
                    aria-label={t('verification.browserViewport', '网页画面')}
                    tabIndex={interactive ? 0 : -1}
                    onKeyDown={handleScreenshotKeyDown}
                    style={{ overflow: 'hidden' }}
                  >
                    {currentShot?.loading && !currentShot.url && (
                      <Group gap="xs" p="sm">
                        <Loader size="xs" />
                        <Text size="xs" c="dimmed">{t('verification.screenshotLoading', '正在加载截图…')}</Text>
                      </Group>
                    )}
                    {currentShot?.error && (
                      <Alert color="red" variant="light" m="sm" p="xs" maw={420}>
                        <Text size="xs">{currentShot.error}</Text>
                      </Alert>
                    )}
                    {currentShot?.url && (
                      <img
                        ref={frameRef}
                        src={currentShot.url}
                        alt={selectedTitle}
                        style={{
                          display: 'block',
                          width: '100%',
                          height: '100%',
                          objectFit: 'contain',
                          cursor: interactivePage ? 'pointer' : 'default',
                          touchAction: interactivePage ? 'none' : undefined,
                        }}
                        onClick={handleScreenshotClick}
                        onPointerDown={handleTouchStart}
                        onPointerMove={handleTouchMove}
                        onPointerUp={handleTouchEnd}
                        onPointerCancel={handleTouchEnd}
                        draggable={false}
                      />
                    )}
                  </Box>
                </Paper>
              </Grid.Col>

              <Grid.Col span={{ base: 12, md: 4 }}>
                <Stack gap="sm">
                  <Group gap="xs">
                    <Badge variant="light" color="brand">{selected.sourceId}</Badge>
                    {selected.kind === 'captcha' && (
                      <Badge variant="light" color="gold">{t('verification.captchaLabel', '验证码')}</Badge>
                    )}
                  </Group>

                  {selected.error && (
                    <Alert color="red" variant="light" p="xs">
                      <Text size="xs">{selected.error}</Text>
                    </Alert>
                  )}
                  {actionError && (
                    <Alert color="red" variant="light" p="xs">
                      <Text size="xs">{actionError}</Text>
                    </Alert>
                  )}

                  {selected.state === 'completed' && resultSummary && (
                    <Alert color="teal" variant="light" p="xs">
                      <Text size="xs">
                        {'status' in resultSummary
                          ? t('verification.resultMeta', { status: resultSummary.status, bytes: resultSummary.bytes, defaultValue: `HTTP ${resultSummary.status} · ${resultSummary.bytes} 字节` })
                          : t('verification.resultPending', '结果尚未就绪')}
                      </Text>
                    </Alert>
                  )}

                  {selected.kind === 'captcha' ? (
                    <Paper p="sm" withBorder radius="md">
                      <TextInput
                        label={t('verification.captchaLabel', '验证码')}
                        value={captchaInput}
                        onChange={event => setCaptchaInput(event.target.value)}
                        placeholder={t('verification.captchaLabel', '验证码')}
                        disabled={!canInteract}
                        autoComplete="off"
                      />
                    </Paper>
                  ) : (
                    <>
                      <Paper p="sm" withBorder radius="md">
                        <Stack gap="xs">
                          <Text size="sm" fw={600}>{t('verification.sendTextTitle', '输入到网页')}</Text>
                          <Text size="xs" c="dimmed">{t('verification.sendTextHint', '先点按网页里的输入框，再输入或粘贴文字。')}</Text>
                          <TextInput
                            size="xs"
                            value={textInput}
                            onChange={event => setTextInput(event.target.value)}
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
                          <Button
                            size="xs"
                            fullWidth
                            disabled={!canInteract || textInput.length === 0}
                            onClick={() => void runInteraction({ action: 'type', text: textInput })}
                          >
                            {t('verification.typeText', '输入文本')}
                          </Button>
                        </Stack>
                      </Paper>

                      <Paper p="sm" withBorder radius="md">
                        <Stack gap="xs">
                          <Text size="sm" fw={600}>{t('verification.quickKeys', '快捷按键')}</Text>
                          <Group gap="xs" grow>
                            {['Enter', 'Tab', 'Backspace', 'Escape'].map(key => (
                              <Button
                                key={key}
                                size="xs"
                                variant="default"
                                disabled={!canInteract}
                                onClick={() => void runInteraction({ action: 'key', key })}
                              >
                                {key}
                              </Button>
                            ))}
                          </Group>
                        </Stack>
                      </Paper>

                      <Paper p="sm" withBorder radius="md">
                        <Stack gap="xs">
                          <Text size="sm" fw={600}>{t('verification.pageTools', '页面工具')}</Text>
                          <Group gap="xs" grow>
                            <Button
                              size="xs"
                              variant="default"
                              leftSection={<Icon name="arrowUp" size={13} />}
                              disabled={!canInteract}
                              onClick={() => void runInteraction({ action: 'scroll', deltaY: -480 })}
                            >
                              {t('verification.scrollUp', '向上滚动')}
                            </Button>
                            <Button
                              size="xs"
                              variant="default"
                              leftSection={<Icon name="arrowDown" size={13} />}
                              disabled={!canInteract}
                              onClick={() => void runInteraction({ action: 'scroll', deltaY: 480 })}
                            >
                              {t('verification.scrollDown', '向下滚动')}
                            </Button>
                          </Group>
                          <Accordion variant="contained" radius="sm">
                            <Accordion.Item value="other-keys">
                              <Accordion.Control py={4}>
                                <Text size="xs" fw={500}>{t('verification.otherKeys', '其他按键')}</Text>
                              </Accordion.Control>
                              <Accordion.Panel>
                                <Group gap="xs" wrap="nowrap">
                                  <TextInput
                                    size="xs"
                                    value={keyInput}
                                    onChange={event => setKeyInput(event.target.value)}
                                    placeholder="Enter"
                                    disabled={!canInteract}
                                    autoComplete="off"
                                    style={{ flex: 1 }}
                                  />
                                  <Button
                                    size="xs"
                                    variant="light"
                                    disabled={!canInteract || keyInput.trim().length === 0}
                                    onClick={() => void runInteraction({ action: 'key', key: keyInput.trim() })}
                                  >
                                    {t('verification.pressKey', '发送按键')}
                                  </Button>
                                </Group>
                              </Accordion.Panel>
                            </Accordion.Item>
                          </Accordion>
                        </Stack>
                      </Paper>
                    </>
                  )}
                </Stack>
              </Grid.Col>
            </Grid>

            <Group justify="flex-end" gap="xs" pt="xs" style={{ borderTop: '1px solid var(--line)' }}>
              <Button variant="default" disabled={busy || !isActiveVerification(selected)} onClick={() => void handleCancel()}>
                {t('verification.cancel', '关闭并取消')}
              </Button>
              <Button
                loading={busy}
                disabled={!canInteract || (selected.kind === 'captcha' && captchaInput.trim().length === 0)}
                onClick={() => void handleComplete()}
              >
                {selected.kind === 'captcha'
                  ? t('verification.completeCaptcha', '提交验证码')
                  : t('verification.completeBrowser', '完成并继续')}
              </Button>
            </Group>
          </Stack>
        </Modal>
      )}
    </>
  )
}
