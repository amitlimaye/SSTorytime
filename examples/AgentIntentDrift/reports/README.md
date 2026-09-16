# reports/ — the natural-language side of each encoding

Every file in `../incidents/` has its source document here. Same slug, `.md`
instead of `.n4l`.

```
reports/2025-coding-agent-deleted-production-database.md   <- what a human wrote
incidents/2025-coding-agent-deleted-production-database.n4l <- what it became
```

## Why the pair matters more than either half

**Reviewability.** An encoding you cannot check against a source is an
assertion. With the pair side by side, a reviewer can ask the only question
that matters: does the N4L say what the report said, and does it say anything
the report did not?

**It is an extraction eval set.** In the intended pipeline a language model
turns prose into N4L once, offline, and a human reviews the diff. These pairs
are how you find out whether that works before trusting it: run extraction on
the `.md`, diff against the `.n4l`, and measure what the model drops, adds or
invents. Four pairs is not a benchmark, but it is enough to catch the
failures that matter, and they are predictable ones:

* the model names a drift mode the report does not support
* the model summarises several trace steps into one and the **first
  departure** disappears into the summary
* the model records what the agent *said* it did rather than what the trace
  shows, which is the exact failure `mode: deceptive reporting` describes
* the model quietly drops the open questions, so uncertainty stops travelling
  with the finding

**It keeps the trace primary.** Each report carries an agent trace excerpt
alongside the human narrative, because the model in this directory insists
that *the report of record is generated from the trace, not from the agent*.
The pairing puts both in front of the reader so the divergence is visible
rather than argued. In
`2025-coding-agent-deleted-production-database.md` that divergence is the
whole incident.

## These are synthetic

**Every report here was written for this repository to exercise the
pipeline. None is a record of a real incident at any real organisation.**

Several are informed by publicly reported events, and the structure and
failure modes are realistic, but the narrative text, timings, identifiers
and trace lines are constructed. Actors are described by role rather than
named for the same reason. Each `.n4l` carries an `(evidence)` class and a
`(tbd)` node saying so, so a query cannot silently treat any of it as
established fact.

Replace these with your own reports before the graph is used for anything
that matters. The value of what is here is the **shape**: it shows what a
report has to contain for the encoding to be possible at all.

## What a report needs to contain

The encoding template asks for things a typical postmortem leaves out. If
your reports do not carry these, the extraction cannot invent them and the
incident will not train a detector:

| the encoding needs | reports usually omit it |
| --- | --- |
| what the agent was **told** to do, verbatim | paraphrased, or lost entirely |
| the trace, step by step, unsummarised | compressed into a narrative |
| what the agent **claimed** it did | only the truth is recorded, after the fact |
| which controls existed and stayed silent | only the control that eventually caught it |
| what is still unknown | written up as though settled |
