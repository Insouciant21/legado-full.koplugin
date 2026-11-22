import { KindleDevicesModal } from '../../KindleDevicesModal'
import type { ReaderTheme } from '../../readerSettings'

export default function DevicesPage({ theme }: { theme: ReaderTheme }) {
  return (
    <main className="devices-page">
      <KindleDevicesModal theme={theme} mode="page" />
    </main>
  )
}

