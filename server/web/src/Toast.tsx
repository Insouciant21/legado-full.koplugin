import type { ReactNode } from 'react'
import { Notifications, notifications } from '@mantine/notifications'
import { Icon } from './icons'

export type ToastType = 'success' | 'info' | 'error' | 'warning'

const COLOR_BY_TYPE: Record<ToastType, string> = {
  success: 'teal',
  info: 'brand',
  warning: 'yellow',
  error: 'red',
}

const ICON_BY_TYPE: Record<ToastType, ReactNode> = {
  success: <Icon name="checkCircle" size={16} />,
  info: <Icon name="bookOpen" size={16} />,
  warning: <Icon name="alert" size={16} />,
  error: <Icon name="alert" size={16} />,
}

export const toast = {
  show(message: string, type: ToastType = 'info', duration = 3000) {
    return notifications.show({
      message,
      color: COLOR_BY_TYPE[type],
      icon: ICON_BY_TYPE[type],
      autoClose: duration > 0 ? duration : false,
      withCloseButton: true,
    })
  },
  dismiss(id: string) {
    notifications.hide(id)
  },
  success(message: string, duration = 2800) {
    return this.show(message, 'success', duration)
  },
  info(message: string, duration = 2800) {
    return this.show(message, 'info', duration)
  },
  error(message: string, duration = 3800) {
    return this.show(message, 'error', duration)
  },
  warning(message: string, duration = 3200) {
    return this.show(message, 'warning', duration)
  },
}

export function ToastContainer() {
  return <Notifications position="top-right" zIndex={4000} limit={4} />
}
