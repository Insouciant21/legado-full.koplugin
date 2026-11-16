import React, { type ReactNode, type SVGProps } from 'react'

type IconName =
  | 'arrowLeft'
  | 'arrowRight'
  | 'book'
  | 'bookmark'
  | 'check'
  | 'chevronDown'
  | 'close'
  | 'cloudDownload'
  | 'columns'
  | 'compass'
  | 'copy'
  | 'device'
  | 'download'
  | 'edit'
  | 'file'
  | 'folder'
  | 'grid'
  | 'image'
  | 'importFile'
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
  | 'settings'
  | 'sliders'
  | 'source'
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
  | 'activity'

const paths: Record<IconName, ReactNode> = {
  activity: <path d="M22 12h-4l-3 9L9 3l-3 9H2" />,
  arrowLeft: <path d="m15 18-6-6 6-6" />,
  arrowRight: <path d="m9 18 6-6-6-6" />,
  book: <><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v16H6.5A2.5 2.5 0 0 0 4 21.5v-16Z" /><path d="M4 19h16" /></>,
  bookmark: <path d="M6 4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v17l-6-3.6L6 21V4Z" />,
  check: <path d="m5 12 4 4L19 6" />,
  chevronDown: <path d="m6 9 6 6 6-6" />,
  close: <path d="m6 6 12 12M18 6 6 18" />,
  // 「网络导入」：云 + 向下的箭头，语义上区别于本地导入用的 upload（托盘 + 上箭头）
  cloudDownload: <><path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z" /><path d="M12 10.5v5" /><path d="m9.8 13.2 2.2 2.2 2.2-2.2" /></>,
  columns: <><rect width="18" height="18" x="3" y="3" rx="2" /><path d="M12 3v18" /></>,
  compass: <><circle cx="12" cy="12" r="9" /><path d="m15.5 8.5-2.1 4.9-4.9 2.1 2.1-4.9 4.9-2.1Z" /></>,
  copy: <><rect width="13" height="13" x="9" y="9" rx="2" /><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" /></>,
  device: <><rect x="5" y="2.5" width="14" height="19" rx="2" /><path d="M9 5h6M11 18.5h2" /></>,
  download: <><path d="M12 3v12" /><path d="m7 10 5 5 5-5" /><path d="M5 21h14" /></>,
  edit: <><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" /><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" /></>,
  file: <><path d="M14 3v5h5" /><path d="M15 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-4-5Z" /></>,
  folder: <path d="M4 6a2 2 0 0 1 2-2h3.6a2 2 0 0 1 1.6.8l1 1.4H18a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6Z" />,
  grid: <><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></>,
  image: <><rect width="18" height="18" x="3" y="3" rx="2" /><circle cx="9" cy="9" r="2" /><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" /></>,
  importFile: <><path d="M12 3v10" /><path d="m8 9 4 4 4-4" /><path d="M4 15v3a3 3 0 0 0 3 3h10a3 3 0 0 0 3-3v-3" /></>,
  library: <><path d="M4 4h4v16H4zM10 4h4v16h-4z" /><path d="m16.5 5 3.5-1 4 15.2-3.5.9z" /></>,
  list: <><path d="M9 6h11M9 12h11M9 18h11" /><path d="M4 6h.01M4 12h.01M4 18h.01" /></>,
  logOut: <><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" /><polyline points="16 17 21 12 16 7" /><line x1="21" y1="12" x2="9" y2="12" /></>,
  menu: <path d="M4 6h16M4 12h16M4 18h16" />,
  more: <path d="M5 12h.01M12 12h.01M19 12h.01" />,
  moon: <path d="M20.4 15.4A8.8 8.8 0 0 1 8.6 3.6 9 9 0 1 0 20.4 15.4Z" />,
  pin: <><line x1="12" y1="17" x2="12" y2="22" /><path d="M5 17h14l-2-6V4H7v7l-2 6Z" /></>,
  pinOff: <><line x1="2" y1="2" x2="22" y2="22" /><line x1="12" y1="17" x2="12" y2="22" /><path d="M5 17h14l-2-6V7M9 4h6v2" /></>,
  plus: <path d="M12 5v14M5 12h14" />,
  refresh: <><path d="M3 12a9 9 0 0 1 15-6.7L21 8" /><path d="M21 3v5h-5" /><path d="M21 12a9 9 0 0 1-15 6.7L3 16" /><path d="M3 21v-5h5" /></>,
  search: <><circle cx="10.8" cy="10.8" r="6.3" /><path d="m16 16 4.2 4.2" /></>,
  settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.8 1.8 0 0 0 .36 1.98l.06.06-2.03 2.03-.06-.06a1.8 1.8 0 0 0-1.98-.36 1.8 1.8 0 0 0-1.1 1.65v.09h-2.88v-.09a1.8 1.8 0 0 0-1.1-1.65 1.8 1.8 0 0 0-1.98.36l-.06.06-2.03-2.03.06-.06A1.8 1.8 0 0 0 7 15a1.8 1.8 0 0 0-1.65-1.1h-.09v-2.88h.09A1.8 1.8 0 0 0 7 9.92a1.8 1.8 0 0 0-.36-1.98l-.06-.06 2.03-2.03.06.06a1.8 1.8 0 0 0 1.98.36 1.8 1.8 0 0 0 1.1-1.65v-.09h2.88v.09a1.8 1.8 0 0 0 1.1 1.65 1.8 1.8 0 0 0 1.98-.36l.06-.06 2.03 2.03-.06.06a1.8 1.8 0 0 0-.36 1.98 1.8 1.8 0 0 0 1.65 1.1h.09v2.88h-.09A1.8 1.8 0 0 0 19.4 15Z" /></>,
  sliders: <><path d="M4 6h16M4 12h16M4 18h16" /><circle cx="9" cy="6" r="2" /><circle cx="15" cy="12" r="2" /><circle cx="11" cy="18" r="2" /></>,
  source: <><circle cx="12" cy="12" r="2" /><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4M4.6 4.6a10.5 10.5 0 0 0 0 14.8M19.4 4.6a10.5 10.5 0 0 1 0 14.8" /></>,
  sun: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.66 6.34l1.41-1.41" /></>,
  trash: <><path d="M4 7h16" /><path d="M10 11v6M14 11v6" /><path d="M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12" /><path d="M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2" /></>,
  upload: <><path d="M12 15V3" /><path d="m7 8 5-5 5 5" /><path d="M5 13v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6" /></>,
  volume2: <><path d="M11 5 6 9H3v6h3l5 4V5Z" /><path d="M15.5 9a4 4 0 0 1 0 6" /><path d="M18.5 6a8 8 0 0 1 0 12" /></>,
  volumeX: <><path d="M11 5 6 9H3v6h3l5 4V5Z" /><line x1="23" y1="9" x2="17" y2="15" /><line x1="17" y1="9" x2="23" y2="15" /></>,
  play: <polygon points="6 3 20 12 6 21 6 3" />,
  pause: <><rect x="6" y="4" width="4" height="16" /><rect x="14" y="4" width="4" height="16" /></>,
  skipBack: <><polygon points="19 20 9 12 19 4 19 20" /><line x1="5" y1="19" x2="5" y2="5" /></>,
  skipForward: <><polygon points="5 4 15 12 5 20 5 4" /><line x1="19" y1="5" x2="19" y2="19" /></>,
  stop: <rect x="5" y="5" width="14" height="14" rx="2" />,
  clock: <><circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" /></>,
}

export function Icon({ name, ...props }: { name: IconName } & SVGProps<SVGSVGElement>) {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>{paths[name]}</svg>
}
