import type { BookDetails, Chapter, ReadingProgress } from './api'

export type OpenBook = {
  details: BookDetails
  bookUrl: string
  chapters: Chapter[]
  progress?: ReadingProgress
  bookKind?: string
}
