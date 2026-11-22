import { createTheme, type CSSVariablesResolver, type MantineColorsTuple } from '@mantine/core'
import type { ReaderTheme } from './readerSettings'

const brandTeal: MantineColorsTuple = [
  '#e6f7f5',
  '#cceee9',
  '#99ded4',
  '#61cbbd',
  '#30b8a6',
  '#0d9488',
  '#0f766e',
  '#115e59',
  '#134e4a',
  '#0d3836',
]

const warmGold: MantineColorsTuple = [
  '#fef9e7',
  '#fdf0c3',
  '#fbe28e',
  '#f8cf55',
  '#f5b724',
  '#d97706',
  '#b45309',
  '#92400e',
  '#78350f',
  '#5c280b',
]

export const legadoTheme = createTheme({
  primaryColor: 'brand',
  primaryShade: { light: 6, dark: 4 },
  colors: {
    brand: brandTeal,
    gold: warmGold,
  },
  defaultRadius: 'md',
  fontFamily: 'Inter, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", system-ui, -apple-system, sans-serif',
  fontFamilyMonospace: '"JetBrains Mono", "Fira Code", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
  headings: {
    fontFamily: '"Noto Serif SC", "Songti SC", Georgia, "Times New Roman", serif',
    fontWeight: '600',
  },
  components: {
    Modal: {
      defaultProps: {
        centered: true,
        radius: 'lg',
        overlayProps: {
          backgroundOpacity: 0.45,
          blur: 3,
        },
      },
    },
    Drawer: {
      defaultProps: {
        overlayProps: {
          backgroundOpacity: 0.4,
          blur: 2,
        },
      },
    },
    Card: {
      defaultProps: {
        withBorder: true,
        radius: 'md',
      },
    },
    Paper: {
      defaultProps: {
        withBorder: true,
        radius: 'md',
      },
    },
    Badge: {
      defaultProps: {
        radius: 'sm',
        fw: 600,
      },
    },
    Button: {
      defaultProps: {
        fw: 600,
      },
    },
    Tooltip: {
      defaultProps: {
        withArrow: true,
        openDelay: 250,
      },
    },
  },
})

export const legadoCssVariablesResolver: CSSVariablesResolver = () => ({
  variables: {},
  light: {
    '--mantine-color-body': 'var(--canvas)',
    '--mantine-color-text': 'var(--ink)',
    '--mantine-color-dimmed': 'var(--muted)',
    '--mantine-color-default': 'var(--surface)',
    '--mantine-color-default-hover': 'var(--surface-hover)',
    '--mantine-color-default-border': 'var(--line)',
    '--mantine-color-default-color': 'var(--ink)',
  },
  dark: {
    '--mantine-color-body': 'var(--canvas)',
    '--mantine-color-text': 'var(--ink)',
    '--mantine-color-dimmed': 'var(--muted)',
    '--mantine-color-default': 'var(--surface)',
    '--mantine-color-default-hover': 'var(--surface-hover)',
    '--mantine-color-default-border': 'var(--line)',
    '--mantine-color-default-color': 'var(--ink)',
  },
})

export function mantineColorSchemeFor(theme: ReaderTheme): 'light' | 'dark' {
  return theme === 'dark' ? 'dark' : 'light'
}

export function applyThemeClasses(theme: ReaderTheme): void {
  if (typeof document === 'undefined') return
  const classes = ['theme-light', 'theme-paper', 'theme-dark']
  document.documentElement.classList.remove(...classes)
  document.documentElement.classList.add(`theme-${theme}`)
  document.documentElement.setAttribute('data-mantine-color-scheme', mantineColorSchemeFor(theme))
  document.body.classList.remove(...classes)
  document.body.classList.add(`theme-${theme}`)
}
