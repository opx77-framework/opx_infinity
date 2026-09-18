import { computed, ref } from 'vue'

/**
 * The one thing the chat's two halves have to agree on.
 *
 * The box is two concerns on two layers -- the LOG on the overlay, which is never
 * focused, and the INPUT line on the modal layer, which takes the keyboard -- and
 * Lua treats them as two independent views: every payload names the layer it
 * belongs to and each half ignores the other's.
 *
 * That split is right everywhere but here. A line in the log fades after
 * `fadeMs` WHILE THE BOX IS CLOSED, and stays put while it is open, so the log
 * has to know something that only ever happens on the other layer. The
 * alternative is the log peeking at payloads addressed to the input, which makes
 * the "ignore the other's payloads" rule true except once -- an exception nobody
 * would find later.
 *
 * So: one flag, written by the input line, read by the log. Nothing else crosses.
 */
const open = ref(false)

/** Whether the input line currently holds the keyboard. */
export const inputOpen = computed(() => open.value)

export function setInputOpen(value: boolean): void {
  open.value = value
}

/**
 * HOW TALL THE INPUT BLOCK IS, IN PIXELS, while it is open.
 *
 * The second thing the two halves have to agree on, and for the same reason as
 * the flag above: the log has to get out of the way of a surface that lives on
 * the other layer and whose height it cannot predict. That height is the field
 * row plus however many completions are on screen -- one to eight rows, changing
 * with every keystroke -- so the clearance the log leaves cannot be a constant in
 * a stylesheet. It is measured on the input line and read here.
 *
 * Zero while the box is closed.
 */
const height = ref(0)

/** How tall the input block is right now, in CSS pixels. */
export const inputHeight = computed(() => height.value)

export function setInputHeight(value: number): void {
  height.value = value
}
