# Plan Review Skill

## Before applying feedback
For each review point, evaluate it as an implementer would:
- Walk through the proposed change concretely: what code would someone actually write?
- Ask whether the feedback is patching a symptom or whether it reveals a deeper architectural flaw that needs a bigger rethink
- If accepting the change adds a new state variable, flag, or interaction surface, ask: does this make the plan simpler or more complex overall? Is there a simpler fix?
- Push back when a patch creates more entanglement. Propose a cleaner alternative rather than just layering complexity.

Do NOT agree with every point automatically. If a suggestion seems wrong or would make the plan worse, say so with a specific technical rationale.

## Applying feedback
1. Read the entire plan document
2. For each review point: evaluate, push back if warranted, then apply agreed changes
3. Re-read the full document and check for:
   - Stale wording from previous versions
   - Broken cross-references or numbering
   - Contradictions between sections
   - Missing callers or incomplete cleanup paths
   - New complexity introduced by this round's changes that could be simplified
4. Fix any issues found before presenting result

## Summary format
End with a concise summary of: what was changed, what was pushed back on (and why), and any new complexity concerns introduced by this round.
