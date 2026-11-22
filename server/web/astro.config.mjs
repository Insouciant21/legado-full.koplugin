import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import react from '@astrojs/react'
import { AstroPWAIntegration } from '@vite-pwa/astro'
import { defineConfig } from 'astro/config'

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
 * Existing installations are controlled by the Vite-era service worker.
 * Append the same activation hook so the first Astro worker takes control and
 * refreshes every open client exactly once.
 */
function pwaActivateReloadPlugin() {
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
      if (!current.includes('legado-activate-reload')) {
        appendFileSync(output, PWA_ACTIVATE_RELOAD)
      }
    },
  }
}

const manifest = {
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
      url: '/library/',
    },
    {
      name: '书源管理',
      short_name: '书源',
      url: '/sources/',
    },
  ],
}

export default defineConfig({
  output: 'static',
  integrations: [
    react(),
    AstroPWAIntegration({
      registerType: 'autoUpdate',
      injectRegister: null,
      includeManifestIcons: false,
      manifest,
      generateSW: {
        globPatterns: ['**/*.{js,css,html,svg,png,ico,woff,woff2,ttf}'],
        navigateFallback: '/',
        navigateFallbackDenylist: [/^\/api\//],
        runtimeCaching: [
          {
            urlPattern: ({ url }) => url.pathname.startsWith('/api/search/stream'),
            handler: 'NetworkOnly',
          },
          {
            urlPattern: ({ url }) => url.pathname.startsWith('/api/covers/'),
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
  ],
  vite: {
    plugins: [pwaActivateReloadPlugin()],
    server: {
      proxy: {
        '/api': process.env.LEGADO_BACKEND_URL || 'http://localhost:8080',
      },
    },
  },
})

