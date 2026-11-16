/** 「清除缓存」的作用域模型（服务器 / 浏览器 / 两者）。 */

/** 用户可选的清理范围。 */
export type ClearCacheScope = 'server' | 'browser' | 'both'

/** 单个清理动作：服务端正文/插图缓存，或浏览器本机 IndexedDB 正文。 */
export type ClearCacheStep = 'content' | 'local'

/** 服务端正文与插图缓存。 */
export const SERVER_CLEAR_STEPS: readonly ClearCacheStep[] = ['content']

/** 浏览器本机一步（本机离线正文）。 */
export const BROWSER_CLEAR_STEPS: readonly ClearCacheStep[] = ['local']

/** 作用域 → 精确步骤序列。三个选项互斥，`both` 只是两者相加。 */
export const SCOPE_STEPS: Readonly<Record<ClearCacheScope, readonly ClearCacheStep[]>> = {
  server: SERVER_CLEAR_STEPS,
  browser: BROWSER_CLEAR_STEPS,
  both: [...SERVER_CLEAR_STEPS, ...BROWSER_CLEAR_STEPS],
}

/**
 * 取某个作用域要执行的步骤。
 *
 * 未知作用域 ⇒ **空数组**（宁可不删，也绝不越界删）：
 * 这个函数是唯一决定"删什么"的地方，宁可少删让用户重试，也不能因为拿到脏值就全删。
 */
export function stepsForScope(scope: ClearCacheScope): readonly ClearCacheStep[] {
  return SCOPE_STEPS[scope] ?? []
}

/** 该步骤是否打在服务端（供 UI 描述与测试区分"服务端/本机"两类动作）。 */
export function isServerStep(step: ClearCacheStep): boolean {
  return step !== 'local'
}
