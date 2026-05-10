---
description: Quick, terse answer using a fast cheap model (Haiku)
argument-hint: <question>
model: claude-haiku-4-5-20251001
---

Answer the user's question in 1-3 sentences. No preamble, no caveats, no "let me know if you need more." Just the answer.

If the question genuinely needs investigation (reading files, running commands, web fetch), do the minimum work needed and still answer in 1-3 sentences. Don't expand scope — `/short` is a request for an answer, not a deep dive.

Question: $ARGUMENTS
