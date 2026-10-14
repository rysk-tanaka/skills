export const meta = {
  name: 'review-router',
  description: 'Run routed pr-review-toolkit reviewers and adversarially verify each finding',
  whenToUse: 'Called by the review-router skill with args { base, diff_cmd, tier, reviewers, context, previous }',
  phases: [
    { title: 'Review', detail: 'routed pr-review-toolkit reviewers in parallel' },
    { title: 'Verify', detail: 'skeptics try to refute each finding against the code' },
  ],
}

const SEVERITIES = ['Must-Fix', 'Important', 'Suggestion']
const MIN_CONFIDENCE = 80
// High-tier Must-Fix candidates get a panel instead of a single skeptic, because a false Must-Fix
// drives an unattended fix loop.
const PANEL_SIZE = 3

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string', description: 'Repo-relative path' },
          line: { type: 'integer', description: '1-indexed line in the current working tree' },
          severity: { type: 'string', enum: SEVERITIES },
          confidence: { type: 'integer', minimum: 0, maximum: 100 },
          summary: { type: 'string', description: 'One-sentence statement of the defect' },
          failure_scenario: { type: 'string', description: 'Concrete inputs/state that lead to the wrong behavior' },
        },
        required: ['file', 'line', 'severity', 'confidence', 'summary', 'failure_scenario'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean', description: 'true if the finding is wrong, already handled, or cannot be confirmed from the code' },
    severity: { type: 'string', enum: SEVERITIES },
    needs_human: { type: 'boolean', description: 'true if fixing it needs a design decision' },
    reason: { type: 'string', description: 'One or two sentences citing the code that settles it' },
  },
  required: ['refuted', 'severity', 'needs_human', 'reason'],
}

// Routing always includes code-reviewer, so missing reviewers means the caller passed bad
// args. Fail loudly: an empty result would read as a clean review and end the fix loop.
if (!args || typeof args !== 'object' || Array.isArray(args)) {
  throw new Error(`args must be an object, got ${typeof args}`)
}
const input = args
const reviewers = input.reviewers
if (!Array.isArray(reviewers) || reviewers.length === 0 || !reviewers.every(r => typeof r === 'string' && r)) {
  throw new Error('args.reviewers must be a non-empty array of reviewer names')
}
const previous = Array.isArray(input.previous) ? input.previous : []
const diffCmd = input.diff_cmd || `git diff ${input.base || 'main'}...HEAD`
const isHighTier = input.tier === 'high'

const previousLines = previous.map(p => `- [${p.status}] ${p.file}:${p.line} ${p.summary}`)

const formatPrevious = () => {
  if (previous.length === 0) return ''
  return [
    '',
    'Findings from earlier rounds, with their status:',
    ...previousLines,
    '- [fixed]: a fix was applied. Check that the fix is correct and complete, and report the finding again if it is not.',
    '- [kept] (left for a human design decision), [suggestion], and [rejected] (refuted by verification): do not report these again.',
  ].join('\n')
}

// Reviewers may ignore the "do not report again" instruction, so the verifier also gets the
// earlier statuses and enforces them; otherwise a re-reported [kept] item could be auto-fixed.
const formatPreviousForVerifier = () => {
  if (previous.length === 0) return ''
  return [
    '',
    'Findings from earlier rounds, with their status:',
    ...previousLines,
    'If this finding is the same issue as an earlier one: [kept] -> set needs_human=true; [suggestion] -> set severity=Suggestion; [rejected] -> set refuted=true unless the code has changed so that the scenario now happens.',
  ].join('\n')
}

// Every reviewer gets the same task; its viewpoint comes from its agentType.
const REVIEW_PROMPT = [
  `Review only the changes shown by \`${diffCmd}\` in the current repository. Do not review code outside that diff.`,
  input.context ? `Purpose of the change: ${input.context}` : '',
  `Report only findings with confidence >= ${MIN_CONFIDENCE}. Use line numbers from the current working tree.`,
  'Severity: Must-Fix = bug, security issue, or data loss that must be fixed before merge; Important = should be fixed but does not block; Suggestion = minor or style.',
  'If nothing qualifies, return an empty findings array.',
  formatPrevious(),
].filter(Boolean).join('\n')

phase('Review')
const reviews = await parallel(reviewers.map(name => () =>
  agent(REVIEW_PROMPT, {
    label: `review:${name}`,
    phase: 'Review',
    agentType: `pr-review-toolkit:${name}`,
    schema: FINDINGS_SCHEMA,
  }).then(r => ({ name, findings: r ? r.findings : null }))
))

const stats = {}
const skipped = []
const raw = []
reviews.forEach((r, i) => {
  const name = reviewers[i]
  if (!r || r.findings === null) {
    skipped.push(name)
    return
  }
  // The prompt already asks for this threshold; filtering again keeps low-confidence findings
  // out of verification even when a reviewer ignores the instruction.
  const confident = r.findings.filter(f => f.confidence >= MIN_CONFIDENCE)
  stats[name] = { reported: confident.length, adopted: 0 }
  confident.forEach(f => raw.push({ ...f, source: name }))
})
if (skipped.length > 0) log(`Skipped reviewers (unavailable or failed): ${skipped.join(', ')}`)
// With no reviewer output there is nothing to call clean; returning empty findings here would
// let the fix loop stop as if the change passed review.
if (skipped.length === reviewers.length) {
  throw new Error(`all reviewers failed: ${skipped.join(', ')}`)
}

// Findings are verified one by one and never merged by location: nearby findings from
// different reviewers can be different defects, and merging would drop one unverified.
// The skill deduplicates the verified results when it reports them.
log(`${raw.length} findings from ${Object.keys(stats).length} reviewers`)

if (raw.length === 0) {
  return { findings: [], rejected: [], unverified: [], stats, skipped }
}

const roster = raw.map((f, i) => `${i + 1}. ${f.file}:${f.line} ${f.summary}`).join('\n')

const verifyPrompt = f => [
  'You are verifying one code review finding against the actual code. Try to refute it.',
  `The change under review is \`${diffCmd}\`. Read the relevant files, not just the diff.`,
  '',
  `Finding: ${f.file}:${f.line} (reported as ${f.severity} by ${f.source})`,
  `Summary: ${f.summary}`,
  `Failure scenario: ${f.failure_scenario}`,
  '',
  'Set refuted=true if the failure scenario cannot actually happen, the code already handles it, or you cannot confirm it from the code. When unsure, refute.',
  'If it stands, set severity: Must-Fix = bug, security issue, or data loss; Important = should be fixed but does not block merge; Suggestion = minor or style.',
  'Set needs_human=true if a fix has several reasonable approaches, changes a spec or public interface, or conflicts with another finding below.',
  '',
  `All findings in this round:\n${roster}`,
  formatPreviousForVerifier(),
].join('\n')

// The majority is taken over the whole panel, not over the votes that came back, so failed
// verifiers cannot let a single vote decide. Without a majority either way the finding is
// returned as unverified rather than silently counted as refuted.
const decide = (votes, panel) => {
  const valid = votes.filter(Boolean)
  const standing = valid.filter(v => !v.refuted)
  const refuting = valid.filter(v => v.refuted)
  if (standing.length * 2 > panel) {
    return {
      outcome: 'kept',
      severity: SEVERITIES[Math.min(...standing.map(v => SEVERITIES.indexOf(v.severity)))],
      needs_human: standing.some(v => v.needs_human),
      reason: standing[0].reason,
    }
  }
  if (refuting.length * 2 > panel) {
    return { outcome: 'rejected', reason: refuting[0].reason }
  }
  return { outcome: 'unverified', reason: `${valid.length}/${panel} verifier votes returned, no majority` }
}

phase('Verify')
const verdicts = await pipeline(raw, f => {
  const panel = isHighTier && f.severity === 'Must-Fix' ? PANEL_SIZE : 1
  return parallel(Array.from({ length: panel }, (_, k) => () =>
    agent(verifyPrompt(f), {
      label: `verify:${f.file}:${f.line}${panel > 1 ? `#${k + 1}` : ''}`,
      phase: 'Verify',
      schema: VERDICT_SCHEMA,
    })
  )).then(votes => decide(votes, panel))
})

const findings = []
const rejected = []
const unverified = []
raw.forEach((f, i) => {
  const v = verdicts[i] || { outcome: 'unverified', reason: 'verification stage failed' }
  const base = { file: f.file, line: f.line, summary: f.summary, source: f.source, reason: v.reason }
  if (v.outcome === 'rejected') {
    rejected.push(base)
    return
  }
  if (v.outcome === 'unverified') {
    unverified.push({ ...base, severity: f.severity, failure_scenario: f.failure_scenario })
    return
  }
  findings.push({ ...base, severity: v.severity, needs_human: v.needs_human, failure_scenario: f.failure_scenario })
  stats[f.source].adopted += 1
})
log(`${findings.length} verified, ${rejected.length} rejected, ${unverified.length} unverified`)

const bySeverity = (a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity)
findings.sort(bySeverity)
unverified.sort(bySeverity)
return { findings, rejected, unverified, stats, skipped }
