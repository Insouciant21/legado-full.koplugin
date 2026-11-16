import type { SearchResult } from './api'

export type SortMode = 'smart' | 'sources' | 'exact' | 'name'

export type SearchGroup = {
  key: string
  name: string
  author?: string
  sources: SearchResult[]
}

export type SearchFilters = {
  query: string
  minimumSources: 1 | 2 | 3
  withIntro: boolean
  withCover: boolean
  sortMode: SortMode
}

export const defaultSearchFilters: SearchFilters = {
  query: '',
  minimumSources: 1,
  withIntro: false,
  withCover: false,
  sortMode: 'smart',
}

export function cleanTitle(raw: string): string {
  if (!raw) return ''
  let cleaned = raw.trim()

  // 1. Remove leading category tags if there is remaining title, e.g. 【都市】重生之大玩家 -> 重生之大玩家
  cleaned = cleaned.replace(/^(\[[^\]]{1,10}\]|【[^】]{1,10}】|《[^》]{1,10}》|（[^）]{1,10}）|\([^)\s]{1,10}\)|「[^」]{1,10}」|『[^』]{1,10}』)(?=\S)/u, (match) => {
    const rest = cleaned.slice(match.length).trim()
    return rest.length >= 2 ? '' : match
  }).trim()

  // 2. Strip surrounding punctuation and brackets
  cleaned = cleaned.replace(/^[\s\p{P}\[\]【】《》""''“”‘’（）()「」『』〈〉]+/gu, '')
                   .replace(/[\s\p{P}\[\]【】《》""''“”‘’（）()「」『』〈〉]+$/gu, '')
                   .trim()

  return cleaned || raw.trim()
}

export function cleanAuthor(raw?: string): string | undefined {
  if (!raw) return undefined
  let cleaned = raw.trim()
  cleaned = cleaned.replace(/^[\s\p{P}\[\]【】《》""''“”‘’（）()「」『』〈〉]+/gu, '')
                   .replace(/[\s\p{P}\[\]【】《》""''“”‘’（）()「」『』〈〉]+$/gu, '')
                   .trim()
  if (!cleaned || cleaned === '未知' || cleaned === '未知作者' || cleaned === 'null' || cleaned === 'undefined') {
    return undefined
  }
  return cleaned
}

const LEADING_RESULT_INDEX = /^\s*\d+\s*[.、．)）:：\-]\s*/u
const TRAILING_BOOK_STATUS = /\s*[\[【(（](?:连载中|已完结|完结|全本|完本|暂停更新|太监|已下架)[\]】)）]\s*$/iu
const KNOWN_EDITION_LABELS = new Set([
  '加料',
  '完整版',
  '未删减',
  '无删减',
  '精校',
  '精校版',
  '修订',
  '修订版',
  '修改',
  '修改版',
])

function normalizeSourceSwitchTitle(raw: string): string {
  let title = raw.trim()
  let previous = ''
  while (title && title !== previous) {
    previous = title
    title = title
      .replace(LEADING_RESULT_INDEX, '')
      .replace(TRAILING_BOOK_STATUS, '')
      .trim()
  }
  const outerWrappers: Array<[string, string]> = [
    ['《', '》'],
    ['「', '」'],
    ['『', '』'],
    ['“', '”'],
    ['"', '"'],
  ]
  for (const [opening, closing] of outerWrappers) {
    if (title.startsWith(opening) && title.endsWith(closing) && title.length > opening.length + closing.length) {
      title = title.slice(opening.length, -closing.length).trim()
      break
    }
  }
  return title.replace(/\s+/gu, ' ').toLocaleLowerCase()
}

function normalizeSourceSwitchAuthor(raw?: string): string {
  return (cleanAuthor(raw) ?? '')
    .replace(/^作者\s*[:：]\s*/u, '')
    .replace(/\s+/gu, '')
    .toLocaleLowerCase()
}

function hasKnownEditionSuffix(shortTitle: string, longTitle: string): boolean {
  if (!longTitle.startsWith(shortTitle)) return false
  const suffix = longTitle.slice(shortTitle.length).trim()
  const match = suffix.match(/^[\[【(（]([^\]】)）]{1,16})[\]】)）]$/u)
  return match ? KNOWN_EDITION_LABELS.has(match[1].trim()) : false
}

/**
 * 换源候选中判断搜索结果是否指向书架上的同一本书。
 *
 * 搜索页常在书名前加结果序号、在书名后加连载状态；这些展示字段不能左右匹配。
 * 若书名还多出“加料 / 修订 / 未删减”等版本标签，只在双方作者都明确且一致时接受，
 * 用来兼容同一本书在不同站的标题修饰，同时避免把同作者的续作或同名作品合并。
 */
export function isSourceSwitchBookMatch(
  candidateName: string,
  targetName: string,
  candidateAuthor?: string,
  targetAuthor?: string,
  checkAuthor: boolean = false,
): boolean {
  const candidateTitle = normalizeSourceSwitchTitle(candidateName)
  const targetTitle = normalizeSourceSwitchTitle(targetName)
  if (!candidateTitle || !targetTitle) return false

  const candidateAuthorKey = normalizeSourceSwitchAuthor(candidateAuthor)
  const targetAuthorKey = normalizeSourceSwitchAuthor(targetAuthor)
  const authorsMatch = Boolean(
    candidateAuthorKey &&
    targetAuthorKey &&
    (
      candidateAuthorKey === targetAuthorKey ||
      candidateAuthorKey.includes(targetAuthorKey) ||
      targetAuthorKey.includes(candidateAuthorKey)
    )
  )

  if (candidateTitle === targetTitle) {
    // Android 在作者为空时仍会执行 `fAuthor.contains(author)`，空字符串恒为真。
    return !checkAuthor || !targetAuthorKey || authorsMatch
  }

  if (!authorsMatch) return false

  const shorterTitle = candidateTitle.length < targetTitle.length ? candidateTitle : targetTitle
  const longerTitle = candidateTitle.length < targetTitle.length ? targetTitle : candidateTitle
  return hasKnownEditionSuffix(shorterTitle, longerTitle)
}

export function calculateRelevanceScore(group: SearchGroup, keyword: string): number {
  const q = cleanTitle(keyword).trim().toLowerCase()
  if (!q) {
    return (group.sources.length * 10) +
      (group.sources.some(s => Boolean(s.coverUrl)) ? 5 : 0) +
      (group.sources.some(s => Boolean(s.intro?.trim())) ? 5 : 0)
  }

  const title = cleanTitle(group.name).toLowerCase()
  const author = (cleanAuthor(group.author) || '').toLowerCase()

  let score = 0

  // 1. Title matching bonuses
  if (title === q) {
    score += 1200
  } else if (title.startsWith(q)) {
    score += 600
  } else if (title.includes(q)) {
    score += 300
  } else if (q.includes(title) && title.length >= 2) {
    score += 200
  } else {
    let matchedChars = 0
    for (const char of q) {
      if (title.includes(char)) matchedChars++
    }
    const ratio = matchedChars / Math.max(q.length, 1)
    if (ratio >= 0.5) {
      score += Math.round(ratio * 150)
    }
  }

  // 2. Author matching bonuses
  if (author) {
    if (author === q) {
      score += 500
    } else if (author.includes(q)) {
      score += 250
    } else if (q.includes(author) && author.length >= 2) {
      score += 200
    }
  }

  // 3. Multi-source popularity bonus
  const sourceCount = group.sources.length
  score += Math.min(sourceCount, 50) * 15
  if (sourceCount >= 3) score += 50
  if (sourceCount >= 5) score += 50

  // 4. Metadata richness bonus
  if (group.sources.some(s => Boolean(s.intro?.trim()))) score += 20
  if (group.sources.some(s => Boolean(s.coverUrl))) score += 20
  if (group.author && cleanAuthor(group.author)) score += 30

  // 5. Title length noise penalty for non-exact matches
  if (title !== q && title.length > q.length) {
    score -= Math.min(60, (title.length - q.length) * 2)
  }

  return score
}

export function sortSearchGroups(groups: SearchGroup[], sortMode: SortMode, keyword: string): SearchGroup[] {
  const result = [...groups]
  switch (sortMode) {
    case 'smart': {
      const scoreCache = new Map<string, number>()
      const getScore = (g: SearchGroup) => {
        let sc = scoreCache.get(g.key)
        if (sc === undefined) {
          sc = calculateRelevanceScore(g, keyword)
          scoreCache.set(g.key, sc)
        }
        return sc
      }
      return result.sort((a, b) => {
        const diff = getScore(b) - getScore(a)
        if (diff !== 0) return diff
        if (b.sources.length !== a.sources.length) return b.sources.length - a.sources.length
        return a.name.localeCompare(b.name, 'zh-Hans-CN')
      })
    }
    case 'sources':
      return result.sort((a, b) => {
        if (b.sources.length !== a.sources.length) return b.sources.length - a.sources.length
        return calculateRelevanceScore(b, keyword) - calculateRelevanceScore(a, keyword)
      })
    case 'exact': {
      const q = cleanTitle(keyword).trim().toLowerCase()
      const getExactRank = (g: SearchGroup) => {
        const t = cleanTitle(g.name).toLowerCase()
        if (t === q) return 0
        if (t.startsWith(q)) return 1
        if (t.includes(q)) return 2 + Math.min(50, t.length - q.length)
        return 100 + Math.min(50, t.length - q.length)
      }
      return result.sort((a, b) => {
        const rankA = getExactRank(a)
        const rankB = getExactRank(b)
        if (rankA !== rankB) return rankA - rankB
        return b.sources.length - a.sources.length
      })
    }
    case 'name':
      return result.sort((a, b) => cleanTitle(a.name).localeCompare(cleanTitle(b.name), 'zh-Hans-CN'))
    default:
      return result
  }
}

export function filterSearchGroups(groups: SearchGroup[], filters: SearchFilters, keyword: string = ''): SearchGroup[] {
  const query = filters.query.trim().toLocaleLowerCase()
  const filtered = groups.filter(group => {
    const searchable = `${group.name} ${group.author ?? ''}`.toLocaleLowerCase()
    return (!query || searchable.includes(query))
      && group.sources.length >= filters.minimumSources
      && (!filters.withIntro || group.sources.some(source => Boolean(source.intro?.trim())))
      && (!filters.withCover || group.sources.some(source => Boolean(source.coverUrl)))
  })
  return sortSearchGroups(filtered, filters.sortMode, keyword)
}

export function isExactMatch(group: SearchGroup, keyword: string): boolean {
  const q = cleanTitle(keyword).trim().toLowerCase()
  if (!q) return false
  const t = cleanTitle(group.name).toLowerCase()
  return t === q
}

export function isPopularMatch(group: SearchGroup): boolean {
  return group.sources.length >= 3
}

