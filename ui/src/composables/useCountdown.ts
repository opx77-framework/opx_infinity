import { computed, onUnmounted, ref, watch } from 'vue'
import type { Ref } from 'vue'

/**
 * Counts down to a deadline Lua set.
 *
 * DISPLAY ONLY. The number on screen is a smooth animation of a deadline the server
 * already decided; it is not a clock anyone acts on. When it reaches zero this does
 * NOT emit, does NOT fire a callback and does NOT let the view proceed -- Lua is
 * counting too, and Lua's count is the one that ends the timer. If the page acted on
 * its own zero, a player whose surface was throttled (an inactive CEF drops to a
 * fraction of its 30fps) would act late, and one with a fast clock would act early.
 *
 * `deadline` is epoch milliseconds as Lua sent it, so a drifting local clock shifts
 * the displayed number and nothing else.
 */
export function useCountdown(deadline: Ref<number>, options: { tickMs?: number } = {}) {
  const tickMs = options.tickMs ?? 250
  const now = ref(Date.now())

  let timer: ReturnType<typeof setInterval> | undefined

  function stop(): void {
    if (timer === undefined) return
    clearInterval(timer)
    timer = undefined
  }

  function start(): void {
    stop()
    now.value = Date.now()
    timer = setInterval(() => {
      now.value = Date.now()
      if (remainingMs.value <= 0) stop()
    }, tickMs)
  }

  const remainingMs = computed(() => Math.max(0, deadline.value - now.value))
  const seconds = computed(() => Math.ceil(remainingMs.value / 1000))
  const done = computed(() => remainingMs.value <= 0)

  /** mm:ss, tabular by construction so the row does not jitter as digits change. */
  const clock = computed(() => {
    const total = seconds.value
    const mm = Math.floor(total / 60)
    const ss = total % 60
    return `${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}`
  })

  watch(
    deadline,
    (value) => {
      if (value > 0) start()
      else stop()
    },
    { immediate: true }
  )

  onUnmounted(stop)

  return { remainingMs, seconds, clock, done, stop }
}
