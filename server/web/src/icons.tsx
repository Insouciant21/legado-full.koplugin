import React from 'react'
import {
  Activity,
  AlertTriangle,
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  BookOpen,
  BookText,
  Bookmark,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Clock,
  CloudDownload,
  Columns2,
  Compass,
  Cookie,
  Copy,
  Download,
  ExternalLink,
  Eye,
  EyeOff,
  FileDown,
  FileText,
  Folder,
  Globe,
  Home,
  Image,
  KeyRound,
  LayoutGrid,
  Library,
  List,
  LogOut,
  Menu,
  Moon,
  MoreHorizontal,
  Pause,
  Pencil,
  Pin,
  PinOff,
  Play,
  Plus,
  Radio,
  RefreshCw,
  Search,
  Send,
  Server,
  Settings,
  SkipBack,
  SkipForward,
  SlidersHorizontal,
  Sparkles,
  Square,
  Sun,
  TabletSmartphone,
  Trash2,
  Upload,
  Volume2,
  VolumeX,
  Wifi,
  X,
  type LucideProps,
} from 'lucide-react'

export type IconName =
  | 'activity'
  | 'alert'
  | 'arrowDown'
  | 'arrowLeft'
  | 'arrowRight'
  | 'arrowUp'
  | 'book'
  | 'bookOpen'
  | 'bookmark'
  | 'check'
  | 'checkCircle'
  | 'chevronDown'
  | 'chevronRight'
  | 'close'
  | 'cloudDownload'
  | 'columns'
  | 'compass'
  | 'cookie'
  | 'copy'
  | 'device'
  | 'download'
  | 'edit'
  | 'externalLink'
  | 'eye'
  | 'eyeOff'
  | 'file'
  | 'folder'
  | 'globe'
  | 'grid'
  | 'home'
  | 'image'
  | 'importFile'
  | 'key'
  | 'library'
  | 'list'
  | 'logOut'
  | 'menu'
  | 'more'
  | 'moon'
  | 'pin'
  | 'pinOff'
  | 'plus'
  | 'refresh'
  | 'search'
  | 'send'
  | 'server'
  | 'settings'
  | 'sliders'
  | 'source'
  | 'sparkles'
  | 'sun'
  | 'trash'
  | 'upload'
  | 'volume2'
  | 'volumeX'
  | 'play'
  | 'pause'
  | 'skipBack'
  | 'skipForward'
  | 'stop'
  | 'clock'
  | 'wifi'

const ICONS: Record<IconName, React.ComponentType<LucideProps>> = {
  activity: Activity,
  alert: AlertTriangle,
  arrowDown: ArrowDown,
  arrowLeft: ArrowLeft,
  arrowRight: ArrowRight,
  arrowUp: ArrowUp,
  book: BookText,
  bookOpen: BookOpen,
  bookmark: Bookmark,
  check: Check,
  checkCircle: CheckCircle2,
  chevronDown: ChevronDown,
  chevronRight: ChevronRight,
  close: X,
  cloudDownload: CloudDownload,
  columns: Columns2,
  compass: Compass,
  cookie: Cookie,
  copy: Copy,
  device: TabletSmartphone,
  download: Download,
  edit: Pencil,
  externalLink: ExternalLink,
  eye: Eye,
  eyeOff: EyeOff,
  file: FileText,
  folder: Folder,
  globe: Globe,
  grid: LayoutGrid,
  home: Home,
  image: Image,
  importFile: FileDown,
  key: KeyRound,
  library: Library,
  list: List,
  logOut: LogOut,
  menu: Menu,
  more: MoreHorizontal,
  moon: Moon,
  pin: Pin,
  pinOff: PinOff,
  plus: Plus,
  refresh: RefreshCw,
  search: Search,
  send: Send,
  server: Server,
  settings: Settings,
  sliders: SlidersHorizontal,
  source: Radio,
  sparkles: Sparkles,
  sun: Sun,
  trash: Trash2,
  upload: Upload,
  volume2: Volume2,
  volumeX: VolumeX,
  play: Play,
  pause: Pause,
  skipBack: SkipBack,
  skipForward: SkipForward,
  stop: Square,
  clock: Clock,
  wifi: Wifi,
}

export function Icon({
  name,
  size = 16,
  strokeWidth = 1.75,
  ...props
}: { name: IconName } & LucideProps) {
  const Component = ICONS[name]
  return <Component size={size} strokeWidth={strokeWidth} aria-hidden="true" {...props} />
}
