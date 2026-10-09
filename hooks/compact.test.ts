import { test, expect, type Engine } from 'claude-code/testing'
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
const capture = (on: On, result: SessionCompactResult = answered()) => {
  const seen: { instructions?: string } = {}
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

// Measures above the threshold first, so the offer is showing before the
// compaction. The hooks beneath stand in for the measurement and the band.
const offered = async ($: Engine, on: On) => {
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Text({ children: 'review' }))
  await $.session.measure({ context: { window: 1_000_000, percent: 60 }, rateLimits: [], changed: ['context'] })
  const ui = await $.ui.mount({
    plugin: 'better-compact',
    surface: 'desktop',
    component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  })
  expect(await ui.find({ key: 'compact' })).toBeDefined()
  return ui
}

test('a successful manual compaction withdraws the offer', async ($, on) => {
  capture(on)
  const ui = await offered($, on)

  await $.session.compact(raise())

  expect(await ui.find({ key: 'compact' })).toBeUndefined()
})

test('a success that spells out an undefined skip withdraws the offer', async ($, on) => {
  capture(on, { ...answered(), skip: undefined })
  const ui = await offered($, on)

  await $.session.compact(raise())

  expect(await ui.find({ key: 'compact' })).toBeUndefined()
})

test("an agent's compaction leaves the offer", async ($, on) => {
  capture(on)
  const ui = await offered($, on)

  await $.session.compact(raise({ agentId: 'a1' }))

  expect(await ui.find({ key: 'compact' })).toBeDefined()
})

test('/clear withdraws the offer', async ($, on) => {
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  const ui = await offered($, on)

  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })

  expect(await ui.find({ key: 'compact' })).toBeUndefined()
})

test('a skipped compaction leaves the offer', async ($, on) => {
  capture(on, { skip: 'nothing to compact' })
  const ui = await offered($, on)

  await $.session.compact(raise())

  expect(await ui.find({ key: 'compact' })).toBeDefined()
})

test('a precompute leaves the offer', async ($, on) => {
  capture(on)
  const ui = await offered($, on)

  await $.session.compact(raise({ trigger: 'precompute' }))

  expect(await ui.find({ key: 'compact' })).toBeDefined()
})
