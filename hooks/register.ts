import type { Register } from 'claude-code'

// The summarizer already has the transcript, so the brief says what to keep
// rather than carrying extracted content. That is why this is a constant and
// not an analysis pass: the only thing missing at compaction time was guidance.
export const BRIEF = [
  'Preserve the following, concretely, and prefer them over narrative:',
  '',
  '- goal: the one-sentence objective of the session as it now stands.',
  '- next: the immediate next action, verb-anchored (edit <path>, run <command>,',
  '  inspect <file> for <issue>, ask user <question>, wait for agent <id>),',
  '  concrete enough to execute without asking the user to restate it.',
  '- files: the minimum set of paths needed to execute next, spec or plan first',
  '  and code after in relevance order. Drop scratch and throwaway files.',
  '- decisions: what was decided and why, constraints the user stated as hard',
  '  requirements or anti-patterns, and unresolved blockers: review findings not',
  '  yet addressed, failing tests, questions awaiting the user.',
  '- state: uncommitted changes, test status with the shortest command that',
  '  reruns them, work left mid-implementation, and any subagent still running.',
  '',
  'Quote paths, identifiers, commands, decisions and constraints verbatim.',
  'Drop exploratory dead ends that were not acted on, unless one underpins a',
  'blocker or a decision that still stands.',
].join('\n')

// 45% of the window. A percentage rather than a token count so it follows the
// model rather than assuming the 1M Opus window.
const WARN_AT_PERCENT = 45

export const register: Register = on => {
  on('session.compact', ($, e, next) => {
    // A manual /compact may carry the user's own text; theirs leads, ours adds
    // the structure. Absent on an automatic compaction, which is the case the
    // skill-and-hook version could never reach.
    const instructions = e.instructions ? `${e.instructions}\n\n${BRIEF}` : BRIEF

    return next({ ...e, instructions })
  })

  // session.measure, not prompt.submit: prompt.submit's next(e) resolves when
  // the turn STARTS, so reading usage there reports the previous turn's figure
  // and the status line lags by one. session.measure carries the live context
  // in its own input, which also removes the $.session.usage() call.
  on('session.measure', ($, e, next) => {
    const { percent } = e.context

    $.ui.status(
      percent !== undefined && percent >= WARN_AT_PERCENT
        ? `context ${percent}% — /compact when convenient`
        : undefined,
    )

    return next(e)
  })
}
