import { test, expect, type Engine } from 'claude-code/testing'
import type { CommandRunArgs, On, SessionMeasureInput } from 'claude-code'

const raise = (percent?: number): SessionMeasureInput => ({
  context: { window: 1_000_000, percent },
  rateLimits: [],
  changed: ['context'],
})

// Nothing beneath the plugins answers in a test, so these stand in: the
// measurement as it came, and another plugin's row in the band.
const beneath = (on: On) => {
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => $.ui.resolve(e).Text({ children: 'review' }))
}

const band = ($: Engine, surface: 'terminal' | 'desktop', { hasSurvey = false, isWorking = false } = {}) =>
  $.ui.mount({
    plugin: 'better-compact',
    surface,
    component: 'AbovePrompt',
    props: { hasSurvey, isWorking, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  })

const isBeneathOnly = async (ui: Awaited<ReturnType<typeof band>>) => {
  expect(await ui.find({ key: 'compact' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'review' })).toBeDefined()
}

for (const surface of ['terminal', 'desktop'] as const) {
  test(`on ${surface}, above the threshold the band offers to compact beside what was beneath`, async ($, on) => {
    beneath(on)
    await $.session.measure(raise(46))

    const ui = await band($, surface)

    expect((await ui.find({ key: 'compact' }))?.text).toBe('context at 46% usage, click to compact')
    expect(await ui.find({ type: 'Text', text: 'review' })).toBeDefined()
  })

  test(`on ${surface}, pressing the offer runs /compact`, async ($, on) => {
    beneath(on)
    let ran: CommandRunArgs | undefined
    on('command.run', (_$, e) => {
      ran = e
      return { text: undefined }
    })
    await $.session.measure(raise(46))
    const ui = await band($, surface)

    await ui.press({ key: 'compact' })

    expect(ran).toMatchObject({ command: 'compact', args: '' })
  })
}

test('the threshold itself shows', async ($, on) => {
  beneath(on)
  await $.session.measure(raise(45))

  const ui = await band($, 'desktop')

  expect((await ui.find({ key: 'compact' }))?.text).toBe('context at 45% usage, click to compact')
})

test('below the threshold the band is left to the plugins beneath', async ($, on) => {
  beneath(on)
  await $.session.measure(raise(46))
  await $.session.measure(raise(44))

  await isBeneathOnly(await band($, 'desktop'))
})

test('an absent percentage withdraws the offer', async ($, on) => {
  beneath(on)
  await $.session.measure(raise(46))
  await $.session.measure(raise(undefined))

  await isBeneathOnly(await band($, 'desktop'))
})

test('a survey keeps the band', async ($, on) => {
  beneath(on)
  await $.session.measure(raise(46))

  await isBeneathOnly(await band($, 'desktop', { hasSurvey: true }))
})

// A press during a turn queues /compact until the session is idle.
test('the offer stays while a turn runs', async ($, on) => {
  beneath(on)
  await $.session.measure(raise(46))

  const ui = await band($, 'desktop', { isWorking: true })

  expect((await ui.find({ key: 'compact' }))?.text).toBe('context at 46% usage, click to compact')
})

test('the hook calls through and returns the measurement', async ($, on) => {
  let reached = false
  on('session.measure', (_$, e) => {
    reached = true
    return { changed: e.changed }
  })

  const result = await $.session.measure(raise(10))

  expect(reached).toBe(true)
  expect(result).toEqual({ changed: ['context'] })
})
