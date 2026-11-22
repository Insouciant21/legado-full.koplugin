import React, { Component, ErrorInfo, ReactNode } from 'react'
import { Alert, Button, Center, Group, Paper, Stack, Text } from '@mantine/core'
import { i18n } from './i18n'
import { Icon } from './icons'

interface Props {
  children: ReactNode
  fallback?: ReactNode
}

interface State {
  hasError: boolean
  error: Error | null
}

export class ErrorBoundary extends Component<Props, State> {
  public state: State = {
    hasError: false,
    error: null,
  }

  public static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error }
  }

  public componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error('Uncaught React error:', error, errorInfo)
  }

  private handleReset = () => {
    this.setState({ hasError: false, error: null })
    if (typeof window !== 'undefined') {
      location.replace('/library/')
    }
  }

  private handleBackToShelf = () => {
    this.setState({ hasError: false, error: null })
    if (typeof window !== 'undefined') {
      location.assign('/library/')
    }
  }

  public render() {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return this.props.fallback
      }
      return (
        <Center mih="60vh" p="lg">
          <Paper p="xl" radius="lg" withBorder maw={480} w="100%">
            <Stack gap="md" align="center" ta="center">
              <Alert
                color="red"
                variant="light"
                icon={<Icon name="alert" size={18} />}
                title={i18n.t('errorBoundary.title')}
                w="100%"
                ta="left"
              >
                <Text size="sm">{this.state.error?.message || i18n.t('errorBoundary.desc')}</Text>
              </Alert>
              <Group gap="sm">
                <Button onClick={this.handleReset}>
                  {i18n.t('errorBoundary.retry')}
                </Button>
                <Button variant="default" onClick={this.handleBackToShelf}>
                  {i18n.t('errorBoundary.backHome')}
                </Button>
              </Group>
            </Stack>
          </Paper>
        </Center>
      )
    }

    return this.props.children
  }
}
