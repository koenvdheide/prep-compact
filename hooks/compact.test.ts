import { test, expect } from 'claude-code/testing'
import type { On, SessionCompactInput, SessionCompactResult } from 'claude-code'
import { BRIEF } from './register'

const raise = (over: Partial<SessionCompactInput> = {}): SessionCompactInput => ({
  trigger: 'manual',
  messages: [{ role: 'assistant' as const, text: 'placeholder', toolUses: [] }],
  ...over,
})

// The engine rejects an empty array: a compaction leaves at least one message.
const answered = () => ({ messages: [{ role: 'assistant' as const, text: 'summary', toolUses: [] }] })

// The bottom hooks fill the holder during the await, so each test reads it after.
// The status line starts as a sentinel, so a test expecting it cleared fails if
// it is never written.
const capture = (on: On, result: SessionCompactResult = answered()) => {
  const seen: { instructions?: string; shown?: string; written: boolean } = { shown: 'stale', written: false }
  on('ui.status', (_$, e) => {
    seen.shown = e.text
    seen.written = true
    return { value: undefined }
  })
  on('session.compact', (_$, e) => {
    seen.instructions = e.instructions
    return result
  })
  return seen
}

test('a compaction with no instructions receives exactly the brief', async ($, on) => {
  const seen = capture(on)

  await $.session.compact(raise())

  expect(seen.instructions).toBe(BRIEF)
})

test("the user's own text leads, then a blank line, then the brief", async ($, on) => {
  const seen = capture(on)

  await $.session.compact(raise({ instructions: 'focus on the parser rewrite' }))

  expect(seen.instructions).toBe('focus on the parser rewrite\n\n' + BRIEF)
})

for (const trigger of ['manual', 'auto', 'plugin', 'precompute'] as const) {
  test(`a ${trigger} compaction is steered`, async ($, on) => {
    const seen = capture(on)

    await $.session.compact(raise({ trigger }))

    expect(seen.instructions).toBe(BRIEF)
  })
}

test("core's messages are returned untouched", async ($, on) => {
  on('session.compact', () => ({
    messages: [{ role: 'assistant' as const, text: 'the summary', toolUses: [] }],
  }))

  const got = await $.session.compact(raise())

  expect(got.messages).toEqual([{ role: 'assistant', text: 'the summary', toolUses: [] }])
})

test('a skipped compaction is returned unchanged', async ($, on) => {
  on('session.compact', () => ({ skip: 'nothing to compact' }))

  const got = await $.session.compact(raise())

  expect(got).toEqual({ skip: 'nothing to compact' })
})

test('a successful manual compaction clears the status line', async ($, on) => {
  const seen = capture(on)

  await $.session.compact(raise())

  expect(seen.shown).toBe(undefined)
})

test('a skipped compaction leaves the status line alone', async ($, on) => {
  const seen = capture(on, { skip: 'nothing to compact' })

  await $.session.compact(raise())

  expect(seen.written).toBe(false)
})

test('a precompute leaves the status line alone', async ($, on) => {
  const seen = capture(on)

  await $.session.compact(raise({ trigger: 'precompute' }))

  expect(seen.written).toBe(false)
})
