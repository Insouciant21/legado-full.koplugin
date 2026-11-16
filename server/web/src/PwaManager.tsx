import { useEffect } from 'react'

export function PwaManager() {
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return

    let disposed = false
    let registration: ServiceWorkerRegistration | null = null
    let refreshing = false
    const hadController = Boolean(navigator.serviceWorker.controller)

    const update = async () => {
      try {
        registration ??= await navigator.serviceWorker.register('/sw.js', { scope: '/' })
        if (!disposed) await registration.update()
      } catch {
        // PWA 不可用不影响在线页面。
      }
    }

    const reloadForNewController = () => {
      if (!hadController || refreshing) return
      refreshing = true
      window.location.reload()
    }
    const updateWhenVisible = () => {
      if (document.visibilityState === 'visible') void update()
    }

    navigator.serviceWorker.addEventListener('controllerchange', reloadForNewController)
    window.addEventListener('online', updateWhenVisible)
    document.addEventListener('visibilitychange', updateWhenVisible)
    void update()
    const timer = window.setInterval(() => void update(), 60_000)

    return () => {
      disposed = true
      window.clearInterval(timer)
      navigator.serviceWorker.removeEventListener('controllerchange', reloadForNewController)
      window.removeEventListener('online', updateWhenVisible)
      document.removeEventListener('visibilitychange', updateWhenVisible)
    }
  }, [])

  return null
}
