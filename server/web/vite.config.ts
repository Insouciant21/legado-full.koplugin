import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const PWA_ACTIVATE_RELOAD = `
/* legado-activate-reload */
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    await self.clients.claim()
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    windows.forEach(client => {
      client.navigate(client.url).catch(() => undefined)
    })
  })())
})
`

/**
 * 旧版页面自身还没有 `controllerchange` 刷新逻辑。
 * 新 SW 首次接管时主动导航一次受控窗口，确保已安装的 PWA 也能脱离旧缓存。
 */
function pwaActivateReloadPlugin(): Plugin {
  return {
    name: 'legado-pwa-activate-reload',
    enforce: 'post',
    apply: 'build',
    generateBundle(_options, bundle) {
      const serviceWorker = bundle['sw.js']
      if (serviceWorker?.type !== 'asset') return
      serviceWorker.source += PWA_ACTIVATE_RELOAD
    },
    closeBundle() {
      const output = resolve(process.cwd(), 'dist/sw.js')
      if (!existsSync(output)) return
      const current = readFileSync(output, 'utf8')
      if (!current.includes('legado-activate-reload')) appendFileSync(output, PWA_ACTIVATE_RELOAD)
    },
  }
}

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      // 服务端升级后旧版工作台不应等待用户手动确认；新 SW 接管时由 PwaManager 刷新一次。
      registerType: 'autoUpdate',
      injectRegister: null,
      includeAssets: ['favicon.svg', 'logo.svg', 'pwa-192x192.svg', 'pwa-512x512.svg', 'maskable-icon-512x512.svg'],
      manifest: {
        name: '阅读',
        short_name: '阅读',
        description: 'Legado 书源、搜书、书架与导出工具',
        lang: 'zh-CN',
        theme_color: '#121820',
        background_color: '#121820',
        display: 'standalone',
        orientation: 'any',
        scope: '/',
        start_url: '/',
        icons: [
          {
            src: '/pwa-192x192.svg',
            sizes: '192x192',
            type: 'image/svg+xml',
            purpose: 'any',
          },
          {
            src: '/pwa-512x512.svg',
            sizes: '512x512',
            type: 'image/svg+xml',
            purpose: 'any',
          },
          {
            src: '/maskable-icon-512x512.svg',
            sizes: '512x512',
            type: 'image/svg+xml',
            purpose: 'maskable',
          },
          {
            src: '/logo.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any',
          },
          {
            src: '/favicon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any',
          },
        ],
        shortcuts: [
          {
            name: '我的书架',
            short_name: '书架',
            url: '/#shelf',
            icons: [{ src: '/favicon.svg', sizes: 'any', type: 'image/svg+xml' }],
          },
          {
            name: '书源管理',
            short_name: '书源',
            url: '/#sources',
            icons: [{ src: '/favicon.svg', sizes: 'any', type: 'image/svg+xml' }],
          },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,ico,woff,woff2,ttf}'],
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api\//],
        runtimeCaching: [
          {
            urlPattern: ({ url }: { url: URL }) => url.pathname.startsWith('/api/search/stream'),
            handler: 'NetworkOnly',
          },
          {
            // 封面接口的真实路径是 /api/covers/<sha256>（见 Routes.kt 的 route("/api") + get("/covers/{key}")）。
            // 此处原先写的是 /api/book/cover —— **该路由不存在**，属于永不命中的死配置，
            // 导致封面既没被缓存、也没被显式排除，语义完全落空，现已修正。
            urlPattern: ({ url }: { url: URL }) => url.pathname.startsWith('/api/covers/'),
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'legado-covers',
              expiration: {
                maxEntries: 300,
                maxAgeSeconds: 30 * 24 * 60 * 60,
              },
            },
          },
        ],
      },
    }),
    pwaActivateReloadPlugin(),
  ],
  server: { proxy: { '/api': process.env.LEGADO_BACKEND_URL || 'http://localhost:8080' } },
})

