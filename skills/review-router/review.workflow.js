export const meta = {
  name: 'review-router',
  description: 'Run routed pr-review-toolkit reviewers, merge duplicate findings, and adversarially verify each one',
  whenToUse: 'Called by the review-router skill with args { base, diff_cmd, tier, reviewers, context, previous }',
  phases: [
    { title: 'Review', detail: 'routed pr-review-toolkit reviewers in parallel' },
    { title: 'Verify', detail: 'skeptics try to refute each merged finding against the code' },
  ],
}

const SEVERITIES = ['Must-Fix', 'Important', 'Suggestion']
const MIN_CONFIDENCE = 80
// Findings this close together in one file are treated as the same issue raised by several reviewers.
const LINE_PROXIMITY = 3
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

const input = args || {}
const reviewers = Array.isArray(input.reviewers) ? input.reviewers : []
const previous = Array.isArray(input.previous) ? input.previous : []
const diffCmd = input.diff_cmd || `git diff ${input.base || 'main'}...HEAD`
const isHighTier = input.tier === 'high'

if (reviewers.length === 0) {
  log('No reviewers given; nothing to run')
  return { findings: [], rejected: [], stats: {}, skipped: [] }
}

const formatPrevious = () => {
  if (previous.length === 0) return ''
  const lines = previous.map(p => `- [${p.status}] ${p.file}:${p.line} ${p.summary}`)
  return [
    '',
    'Findings from earlier rounds, with their status:',
    ...lines,
    '- [fixed]: a fix was applied. Check that the fix is correct and complete, and report the finding again if it is not.',
    '- [kept] (left for a human design decision) and [suggestion]: do not report these again.',
  ].join('\n')
}

const reviewPrompt = name => [
  `Review only the changes shown by \`${diffCmd}\` in the current repository. Do not review code outside that diff.`,
  input.context ? `Purpose of the change: ${input.context}` : '',
  `Report only findings with confidence >= ${MIN_CONFIDENCE}. Use line numbers from the current working tree.`,
  'Severity: Must-Fix = bug, security issue, or data loss that must be fixed before merge; Important = should be fixed but does not block; Suggestion = minor or style.',
  'If nothing qualifies, return an empty findings array.',
  formatPrevious(),
].filter(Boolean).join('\n')

phase('Review')
const reviews = await parallel(reviewers.map(name => () =>
  agent(reviewPrompt(name), {
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
  const confident = r.findings.filter(f => f.confidence >= MIN_CONFIDENCE)
  stats[name] = { reported: confident.length, adopted: 0 }
  confident.forEach(f => raw.push({ ...f, source: name }))
})
if (skipped.length > 0) log(`Skipped reviewers (unavailable or failed): ${skipped.join(', ')}`)

// Merge findings that point at the same spot. Severity order is the array index, so the
// most severe report becomes the representative. A reviewer does not repeat itself, so two
// nearby findings from the same reviewer are distinct issues and stay separate.
const merged = []
raw
  .slice()
  .sort((a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity))
  .forEach(f => {
    const same = merged.find(m =>
      m.file === f.file &&
      Math.abs(m.line - f.line) <= LINE_PROXIMITY &&
      !m.sources.includes(f.source))
    if (same) {
      same.sources.push(f.source)
      same.related.push(f.summary)
      return
    }
    merged.push({ ...f, sources: [f.source], related: [] })
  })
log(`${raw.length} findings from ${Object.keys(stats).length} reviewers, ${merged.length} after merging`)

if (merged.length === 0) {
  return { findings: [], rejected: [], stats, skipped }
}

const roster = merged.map((m, i) => `${i + 1}. ${m.file}:${m.line} ${m.summary}`).join('\n')

const verifyPrompt = m => [
  'You are verifying one code review finding against the actual code. Try to refute it.',
  `The change under review is \`${diffCmd}\`. Read the relevant files, not just the diff.`,
  '',
  `Finding: ${m.file}:${m.line} (reported as ${m.severity} by ${m.sources.join(', ')})`,
  `Summary: ${m.summary}`,
  `Failure scenario: ${m.failure_scenario}`,
  m.related.length > 0 ? `Related reports at the same spot:\n${m.related.map(s => `- ${s}`).join('\n')}` : '',
  '',
  'Set refuted=true if the failure scenario cannot actually happen, the code already handles it, or you cannot confirm it from the code. When unsure, refute.',
  'If it stands, set severity: Must-Fix = bug, security issue, or data loss; Important = should be fixed but does not block merge; Suggestion = minor or style.',
  'Set needs_human=true if a fix has several reasonable approaches, changes a spec or public interface, or conflicts with another finding below.',
  '',
  `All findings in this round:\n${roster}`,
].filter(s => s !== null && s !== undefined).join('\n')

const decide = (m, votes) => {
  const valid = votes.filter(Boolean)
  const standing = valid.filter(v => !v.refuted)
  const survives = standing.length > 0 && standing.length * 2 > valid.length
  if (!survives) {
    return { kept: false, reason: (valid.find(v => v.refuted) || {}).reason || 'no verdict returned' }
  }
  const severity = SEVERITIES[Math.min(...standing.map(v => SEVERITIES.indexOf(v.severity)))]
  return {
    kept: true,
    severity,
    needs_human: standing.some(v => v.needs_human),
    reason: standing[0].reason,
  }
}

phase('Verify')
const verdicts = await pipeline(merged, m => {
  const voters = isHighTier && m.severity === 'Must-Fix' ? PANEL_SIZE : 1
  return parallel(Array.from({ length: voters }, (_, k) => () =>
    agent(verifyPrompt(m), {
      label: `verify:${m.file}:${m.line}${voters > 1 ? `#${k + 1}` : ''}`,
      phase: 'Verify',
      schema: VERDICT_SCHEMA,
    })
  )).then(votes => decide(m, votes))
})

const findings = []
const rejected = []
merged.forEach((m, i) => {
  const v = verdicts[i] || { kept: false, reason: 'verification failed' }
  const base = { file: m.file, line: m.line, summary: m.summary, sources: m.sources, reason: v.reason }
  if (!v.kept) {
    rejected.push(base)
    return
  }
  findings.push({ ...base, severity: v.severity, needs_human: v.needs_human, failure_scenario: m.failure_scenario })
  m.sources.forEach(s => { if (stats[s]) stats[s].adopted += 1 })
})
log(`${findings.length} findings survived verification, ${rejected.length} rejected`)

findings.sort((a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity))
return { findings, rejected, stats, skipped }
