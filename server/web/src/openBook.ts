import type { BookDetails, Chapter, ReadingProgress, SourceLoginBookRefresh, SourceLoginContext } from './api'

export type OpenBook = {
  details: BookDetails
  bookUrl: string
  chapters: Chapter[]
  progress?: ReadingProgress
  bookKind?: string
}

export function sourceLoginContext(book: OpenBook, chapter?: Chapter): SourceLoginContext {
  return {
    book: {
      sourceId: book.details.sourceId,
      bookUrl: book.bookUrl,
      name: book.details.name,
      author: book.details.author,
      tocUrl: book.details.tocUrl,
      bookKind: book.bookKind || book.details.bookKind,
      variables: book.details.variables,
    },
    chapter,
  }
}

export function applySourceLoginBookRefresh(book: OpenBook, refresh: SourceLoginBookRefresh): OpenBook {
  return {
    ...book,
    details: {
      ...book.details,
      ...refresh.details,
      name: refresh.details?.name || book.details.name,
      coverUrl: refresh.details?.coverUrl ?? book.details.coverUrl,
      intro: refresh.details?.intro ?? book.details.intro,
      tocUrl: refresh.tocUrl ?? refresh.details?.tocUrl ?? book.details.tocUrl,
      variables: refresh.variables ?? refresh.details?.variables ?? book.details.variables,
    },
    bookKind: refresh.details?.bookKind ?? book.bookKind,
    chapters: refresh.chapters ?? book.chapters,
  }
}
