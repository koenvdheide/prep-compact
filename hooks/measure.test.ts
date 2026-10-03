import { test, expect } from 'claude-code/testing'
import type { SessionMeasureInput } from 'claude-code'

const raise = (percent?: number): SessionMeasureInput => ({
  context: { window: 1_000_000, percent },
  rateLimits: [],
  changed: ['context'],
})

test('above the threshold the status line names the percentage', async ($, on) => {
  let shown: string | undefined
  on('ui.status', (_$, e) => {
    shown = e.text
    return { value: undefined }
  })
  on('session.measure', (_$, e) => ({ changed: e.changed }))

  await $.session.measure(raise(46))

  expect(shown).toBe('context 46% — /compact when convenient')
})

test('the threshold itself shows', async ($, on) => {
  let shown: string | undefined
  on('ui.status', (_$, e) => {
    shown = e.text
    return { value: undefined }
  })
  on('session.measure', (_$, e) => ({ changed: e.changed }))

  await $.session.measure(raise(45))

  expect(shown).toBe('context 45% — /compact when convenient')
})

test('below the threshold the status line is cleared', async ($, on) => {
  let shown: string | undefined = 'stale'
  on('ui.status', (_$, e) => {
    shown = e.text
    return { value: undefined }
  })
  on('session.measure', (_$, e) => ({ changed: e.changed }))

  await $.session.measure(raise(44))

  expect(shown).toBe(undefined)
})

test('an absent percentage clears rather than guesses', async ($, on) => {
  let shown: string | undefined = 'stale'
  on('ui.status', (_$, e) => {
    shown = e.text
    return { value: undefined }
  })
  on('session.measure', (_$, e) => ({ changed: e.changed }))

  await $.session.measure(raise(undefined))

  expect(shown).toBe(undefined)
})

test('the measurement result is returned, not dropped', async ($, on) => {
  on('ui.status', () => ({ value: undefined }))
  on('session.measure', (_$, e) => ({ changed: e.changed }))

  const got = await $.session.measure(raise(10))

  expect(got).toEqual({ changed: ['context'] })
})
