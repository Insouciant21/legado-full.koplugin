import { Badge } from '@mantine/core'
import { useTranslation } from 'react-i18next'

export function ShelfKindTag({ bookKind, local }: { bookKind?: string; local?: boolean }) {
  const { t } = useTranslation()
  if (local || bookKind === 'local') {
    return <Badge size="xs" variant="filled" color="gold">{t('shelf.localTag', '本地')}</Badge>
  }
  if (bookKind === 'comic') {
    return <Badge size="xs" variant="filled" color="indigo">{t('shelf.comicTag', '漫画')}</Badge>
  }
  if (bookKind === 'audio') {
    return <Badge size="xs" variant="filled" color="cyan">{t('shelf.audioTag', '听书')}</Badge>
  }
  return <Badge size="xs" variant="filled" color="brand">{t('shelf.novelTag', '小说')}</Badge>
}
