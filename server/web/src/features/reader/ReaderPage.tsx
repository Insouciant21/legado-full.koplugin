import type { SourceSummary } from '../../api'
import type { OpenBook } from '../../openBook'
import type { ReaderTheme } from '../../readerSettings'
import { TextReaderScreen } from '../../TextReaderScreen'

export default function ReaderPage({
  book,
  startIndex,
  theme,
  onClose,
  onBookChange,
  source,
}: {
  book: OpenBook
  startIndex: number
  theme: ReaderTheme
  onClose: () => void
  onBookChange: (book: OpenBook, index: number) => void
  source?: SourceSummary
}) {
  return <TextReaderScreen openBook={book} startIndex={startIndex} onClose={onClose} onBookChange={onBookChange} source={source} theme={theme} />
}
