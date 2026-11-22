import { Loader } from '@mantine/core'

export interface ButtonSpinnerProps {
  size?: number | 'sm' | 'md' | 'lg'
  className?: string
  label?: string
}

const PRESET_SIZE: Record<'sm' | 'md' | 'lg', number> = {
  sm: 12,
  md: 14,
  lg: 18,
}

export function ButtonSpinner({ size = 'md', className = '', label = 'loading' }: ButtonSpinnerProps) {
  const px = typeof size === 'number' ? size : PRESET_SIZE[size]
  return (
    <Loader
      size={px}
      color="currentColor"
      className={className || undefined}
      aria-label={label}
    />
  )
}
