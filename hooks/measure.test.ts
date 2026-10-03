import { test, expect } from 'claude-code/testing'
import type { On, SessionMeasureInput } from 'claude-code'

const raise = (percent?: number): SessionMeasureInput => ({
  context: { window: 1_000_000, percent },
  rateLimits: [],
  changed: ['context'],
})

// The bottom hooks fill the holder during the await. A test expecting a cleared
// status line passes a sentinel, so it fails if the status is never written.
const capture = (on: On, sentinel?: string) => {
  const got = { shown: sentinel, reached: false }
  on('ui.status', (_$, e) => {
    got.shown = e.text
    return { value: undefined }
  })
  on('session.measure', (_$, e) => {
    got.reached = true
    return { changed: e.changed }
  })
  return got
}

test('above the threshold the status line names the percentage', async ($, on) => {
  const got = capture(on)

  await $.session.measure(raise(46))

  expect(got.shown).toBe('context 46% — /compact when convenient')
})

test('the threshold itself shows', async ($, on) => {
  const got = capture(on)

  await $.session.measure(raise(45))

  expect(got.shown).toBe('context 45% — /compact when convenient')
})

test('below the threshold the status line is cleared', async ($, on) => {
  const got = capture(on, 'stale')

  await $.session.measure(raise(44))

  expect(got.shown).toBe(undefined)
})

test('an absent percentage clears rather than guesses', async ($, on) => {
  const got = capture(on, 'stale')

  await $.session.measure(raise(undefined))

  expect(got.shown).toBe(undefined)
})

test('the hook calls through and returns the measurement', async ($, on) => {
  const got = capture(on)

  const result = await $.session.measure(raise(10))

  expect(got.reached).toBe(true)
  expect(result).toEqual({ changed: ['context'] })
})
