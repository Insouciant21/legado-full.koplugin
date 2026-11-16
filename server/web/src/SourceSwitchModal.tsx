/**
 * 兼容入口：换源实现已抽到 `sourceSwitch.tsx`（弹窗与编排）
 * 与 `sourceSwitchRemap.ts`（重映射纯函数）。
 *
 * 保留这个兼容入口，让既有调用继续指向同一实现。
 * 新代码请直接从 `./sourceSwitch` 引入。
 */
export { SourceSwitchModal, matchBestChapter } from './sourceSwitch'
export type { SourceCandidate, SourceSwitchModalProps } from './sourceSwitch'
