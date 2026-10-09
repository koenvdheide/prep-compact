import type { EngineInterface, Register } from 'claude-code'

// The summarizer already has the transcript, so the brief only says what to
// keep. Guidance was the one thing missing at compaction time, so a constant
// does the whole job.
export const BRIEF = [
  'Preserve the following, concretely, and prefer them over narrative:',
  '',
  '- goal: the one-sentence objective of the session as it now stands.',
  '- next: the immediate next action, verb-anchored (edit <path>, run <command>,',
  '  inspect <file> for <issue>, ask user <question>, wait for agent <id>),',
  '  concrete enough to execute without asking the user to restate it.',
  '- files: the minimum set of paths needed to execute next, spec or plan first',
  '  and code after in relevance order. Drop scratch and throwaway files.',
  '- decisions: what was decided and why, and constraints the user stated as',
  '  hard requirements or anti-patterns.',
  '- blockers: review findings not yet addressed, failing tests, questions',
  '  awaiting the user.',
  '- state: uncommitted changes, test status with the shortest command that',
  '  reruns them, work left mid-implementation, and any subagent still running.',
  '',
  'Quote paths, identifiers, commands, decisions and constraints verbatim.',
  'Drop exploratory dead ends that were not acted on, unless one underpins a',
  'blocker or a decision that still stands.',
].join('\n')

// 45% of the window, so the threshold tracks whatever window the model has.
// A token count would pin it to the 1M Opus window.
const WARN_AT_PERCENT = 45

// The percentage the band offers to compact at; undefined, no offer.
let nudge: number | undefined

function offer($: EngineInterface, percent: number | undefined) {
  nudge = percent
  $.ui.invalidate('ui.render')
}

export const register: Register = on => {
  on('session.compact', async ($, e, next) => {
    // A manual /compact may carry the user's own text; theirs leads, ours adds
    // the structure. Absent on an automatic compaction, which is the case the
    // skill-and-hook version could never steer.
    const instructions = e.instructions ? `${e.instructions}\n\n${BRIEF}` : BRIEF

    const result = await next({ ...e, instructions })

    // session.measure fires after a main-thread turn, so nothing clears the
    // nudge until the next one and it sits at its pre-compaction figure. A
    // precompute installs nothing and a skip leaves the context as it was, so
    // in both the nudge is still true. An agent's compaction leaves the main
    // conversation, which the nudge measures, as it was.
    if (e.trigger !== 'precompute' && e.agentId === undefined && result.skip === undefined) {
      offer($, undefined)
    }

    return result
  })

  // /clear starts a fresh conversation with no turn behind it, so no
  // measurement would replace the ended one's figure.
  on('session.end', ($, e, next) => {
    offer($, undefined)
    return next(e)
  })

  // prompt.submit's next(e) resolves when the turn STARTS, so reading usage
  // there reports the previous turn's figure and the nudge lags by one.
  // session.measure carries the live context in its own input, which also
  // removes the $.session.usage() call.
  on('session.measure', ($, e, next) => {
    const { percent } = e.context

    offer($, percent !== undefined && percent >= WARN_AT_PERCENT ? percent : undefined)

    return next(e)
  })

  // The status line takes plain text, so the nudge is a Button in the band
  // above the prompt; a Button drawn in the hint line under it did not show on
  // the desktop (2.1.293). The band holds one tree, so this wraps what the
  // plugins beneath drew.
  // A press runs /compact as if typed, so core raises the compaction and the
  // session.compact hook above adds the brief.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (nudge === undefined || e.props.hasSurvey) return next(e)

    const beneath = await next(e)
    const { Box, Button } = $.ui.resolve(e)

    return (
      <Box gap={2}>
        {beneath}
        <Button
          key="compact"
          label={`context at ${nudge}% usage, click to compact`}
          plain
          dimColor
          onPress={() => $.command.run({ command: 'compact' })}
        />
      </Box>
    )
  })
}
