import React, { FormEvent, useState } from 'react'
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
    <main className="login-shell">
      <section className="login-story" aria-label={t('login.brand')}>
        <div className="login-story-glow" aria-hidden="true" />
        <div className="login-story-mark">
          <Logo size={34} />
          <strong>{t('login.brand')}</strong>
        </div>
        <div className="login-story-copy">
          <span className="login-story-eyebrow">PRIVATE READING WORKSPACE</span>
          <h1>把书源、书架和阅读，留在自己的网络里。</h1>
          <p>一套由你掌控的阅读工作流。搜索、缓存、导出和 Kindle 同步，都从这台服务器出发。</p>
        </div>
        <div className="login-feature-grid">
          <span><Icon name="source" /><b>书源可维护</b><small>导入、校验与登录</small></span>
          <span><Icon name="library" /><b>书架可沉淀</b><small>进度、分组与阅读</small></span>
          <span><Icon name="device" /><b>Kindle 可同步</b><small>上架、推送与回读</small></span>
        </div>
        <footer>局域网私有部署 · 数据仅保存在你的服务器</footer>
      </section>
      <form className="login-panel" onSubmit={submit}>
        <span className="login-form-kicker">ADMIN ACCESS</span>
        <div className="login-mark">
          <Logo size={28} />
          <strong>{t('login.brand')}</strong>
        </div>
        <h1>{t('login.title')}</h1>
        <p>{t('login.desc')}</p>
        <label>
          {t('login.password')}
          <input
            autoFocus
            type="password"
            value={password}
            onChange={event => setPassword(event.target.value)}
            required
            placeholder={t('login.passwordPlaceholder')}
          />
        </label>
        {error && (
          <p className="form-error" role="alert">
            {error}
          </p>
        )}
        <button type="submit" className="primary-button" disabled={busy}>
          {busy ? t('login.submitting') : t('login.submit')}
        </button>
      </form>
    </main>
  )
}
