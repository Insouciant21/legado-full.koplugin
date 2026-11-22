/**
 * Reads the Android Legado `Book.variable` JSON without allowing malformed
 * historical data to break editing or opening a book.
 */
export function readCustomVariable(raw?: string): string {
  if (!raw) return ''
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown> | null
    const value = parsed && typeof parsed === 'object' ? parsed.custom : undefined
    return typeof value === 'string' ? value : ''
  } catch {
    return ''
  }
}

export function parseBookVariables(raw?: string): Record<string, string> {
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>
    return Object.fromEntries(
      Object.entries(parsed).filter((entry): entry is [string, string] => typeof entry[1] === 'string')
    )
  } catch {
    return {}
  }
}
