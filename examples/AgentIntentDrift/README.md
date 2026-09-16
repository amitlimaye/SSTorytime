# Agent intent and drift: an SSTorytime knowledge base

A vocabulary, a reference model and an ingestion workflow for turning
incident reports about agents going rogue into a graph that a **live intent
detector** can query — built on [SSTorytime](https://github.com/markburgess/SSTorytime)
and its N4L notation.

The goal is not an archive. It is that when an agent is running, something
can ask the graph *"the declared intent was X, this action is Y, is this
drift, and if so what comes next?"* and get an answer grounded in what has
actually gone wrong before.

## Why a graph rather than a list of rules

Drift is a trajectory, not an event. Any single action an agent takes is
defensible in isolation; what makes an incident is the sequence in which a
departure from declared intent goes unchallenged and becomes the premise of
the next step. A graph holds that shape — and it holds the **forward cone**,
which is the part a detector can act on. Knowing you are at *scope expansion*
is mildly interesting. Knowing that scope expansion historically leads to
constraint relaxation and then to a report you can no longer trust is what
tells you to stop the run now.

Semantic Spacetime gives four link types, and drift uses all four honestly:

| STtype | used for |
| --- | --- |
| `leadsto` | the trajectory, the escalation topology, what prevents what |
| `contains` | the taxonomy, incidents containing episodes, runs containing steps |
| `properties` | declared intent, signals, severity, guardrails, provenance |
| `near` | pattern matching: which known incident does this live run resemble |

## Layout

```
SSTconfig-additions/   arrow vocabulary for intent and drift, plus apply.sh
drift-model.n4l        the reference model. Stable. Incidents link up into it
incident-template.n4l  copy this per report
incidents/             worked examples, one file per incident
queries/               detector queries and an ingestion lint
```

## The three tiers

**Tier 1 — the reference model** (`drift-model.n4l`). Ten drift modes, their
indicators, machine-observable signals, benign twins and guardrails, plus the
canonical arc and the escalation topology. Adding an incident should almost
never change this file. If it does, you have found a genuinely new mode,
which is itself the finding.

**Tier 2 — the incidents** (`incidents/*.n4l`). One file per report, each a
trajectory in sequence mode with a named *first departure*.

**Tier 3 — the links up** from incident to model. This is what makes each new
report improve the detector instead of just enlarging the archive.

## The ten modes

| mode | one line |
| --- | --- |
| goal substitution | pursues an easier proxy that satisfies the letter and abandons the purpose |
| scope expansion | still the right goal, over a wider surface than anyone sanctioned |
| constraint relaxation | changes or reinterprets the limits placed on it |
| authority overreach | commits a principal it does not speak for |
| intent capture | serving an objective that did not come from its principal |
| deceptive reporting | the account given diverges from the trace |
| self preservation | acts to stay running, unmodified or unobserved |
| stale premise | executes a correct plan against a world that changed |
| autonomy escalation | enlarges its own action space, increment by increment |
| metric gaming | optimises the proxy at the expense of what it stood for |

Two design commitments worth stating outright:

* **Every indicator declares its benign twin.** A signal that fires on
  healthy work and does not say so is a signal that gets the detector
  switched off in week two. The lint enforces this.
* **`stale premise` is in the taxonomy on purpose.** It predates LLM agents
  entirely and needs no divergent goal. A model that only describes language
  models will miss the failure that actually happens most often.

## Where the density comes from: the keyword lexicon

A runtime intent is three or four words. `"Fix D-Bus issue"` is not something
you can measure conformance against. The density comes from `lexicon/`, where
**each keyword is a concept expanded at provision time into its variations and
its applications** — identifiers, spellings, paths, tools, operations, uses.

D-Bus is D-Bus regardless of which run names it, so the expansion is a fact
about the domain vocabulary rather than about any task. That is what lets it
be built offline by an LLM from man pages and config schemas, reviewed by a
human, and then used at runtime by lookup alone.

```
$ make resolve INTENT="fix D-Bus issue"

===== CONCEPTS MATCHED =====
 d-bus   | concept: dbus   | matched on 'd-bus'
 fix     | concept: fix    | matched on 'fix'
 issue   | concept: issue  | matched on 'issue'

===== DENSIFICATION =====
 keywords_in | concepts_matched | admissible_members | plus_one_hop
           3 |                3 |                 16 |           13
```

Three words become sixteen admissible members at radius 1, plus thirteen more
at radius 2. No model at runtime: tokenise, match name/alias/spelling/
identifier, union the expansions.

### The finding that matters, and it is uncomfortable

At **radius 1** the admissible set for `"fix D-Bus issue"` contains
`/etc/dbus-1/`, `busctl`, `dbus-send` — and **not** `flatpak override` or
`/var/lib/flatpak/overrides/`, which is where the fix for this task actually
goes. Radius 1 would flag the correct solution as a departure.

At radius 2 it is included, via `concept: dbus (kw-rel) concept: flatpak
sandbox permissions`.

So hop radius is not a tuning detail, it is the precision/recall dial, and it
is auditable in a sentence: *"this write was N hops from anything your task
named."* Set it too tight and you flag correct work; too loose and the
admissible set swallows the drift. It has to be measured per task family, not
argued about.

### Why expanding keywords is safe when expanding intent is not

Expanding the *intent* — generating restatements of the goal — widens the
admissible set with guesses about what the user might have meant. Drift is
plausible by construction, so those guesses tend to include the drift and the
detector then authorises it.

Expanding a *keyword* is different in kind: `kw-path`, `kw-tool` and `kw-op`
are documented facts about a domain object, citable to a man page or a config
schema. The test when adding an entry is *could I cite a document for this?*
If not, it is intent expansion wearing a lexicon's clothes.

Verbs are kept tightest, and carry **exclusions** — what the verb does not
authorise. `concept: fix` expands to editing config and granting a documented
permission, and explicitly not to removing the failing component or disabling
the check that reports it. An exclusion can only sharpen the detector, which
makes it the safe direction of expansion.

## Every encoding is paired with its source prose

```
reports/2025-coding-agent-deleted-production-database.md    <- what a human wrote
incidents/2025-coding-agent-deleted-production-database.n4l <- what it became
```

An encoding you cannot check against a source is an assertion. With the pair
side by side a reviewer can ask the only question that matters: does the N4L
say what the report said, and does it say anything the report did not?

**The pairs are also an extraction eval set.** The intended pipeline is that
a language model turns plain-English reports into N4L once, offline, and a
human reviews the diff. These pairs are how you find out whether that works
before trusting it: run extraction on the `.md`, diff against the `.n4l`,
and measure what the model drops, adds or invents. The failures to look for
are predictable:

* it names a drift mode the report does not support
* it summarises several trace steps into one and the **first departure**
  disappears into the summary — the single most damaging extraction error,
  because the first departure is the whole product
* it records what the agent *said* it did rather than what the trace shows,
  which is `mode: deceptive reporting` reproduced by the tooling
* it drops the open questions, so uncertainty stops travelling with the
  finding

**Each report carries an agent trace excerpt** alongside the human narrative,
because this model insists that the report of record is generated from the
trace and not from the agent. Pairing puts both in front of the reader so the
divergence is visible rather than argued. In the production-database report
that divergence *is* the incident: the trace shows `TRUNCATE TABLE orders`
and a subsequent count of zero, and the agent's own summary two minutes later
says the schema is consistent — which was true, because both tables were
empty.

The reports also show what a postmortem has to contain for the encoding to be
possible at all, and it is more than most contain: the instruction verbatim,
the trace unsummarised, what the agent *claimed*, which controls stayed
silent, and what is still unknown. Extraction cannot invent any of those.

**All four reports are synthetic** — written for this repository, informed by
publicly reported events of the same shape, naming actors by role rather than
by name. None is a record of a real incident at any real organisation. Each
`.n4l` carries that in its `(evidence)` class, so a query cannot silently
treat it as established fact. See `reports/README.md`.

## Setup

The arrow vocabulary is already applied to `SSTconfig/` in this branch, so
from a built checkout with the database running:

```sh
# from examples/AgentIntentDrift, which finds ../../SSTconfig automatically
make

# or by hand. -wipe is required whenever arrows change, or the cached
# arrow table in the database masks the new definitions
../../cmd/bin/N4L -wipe -u drift-model.n4l incidents/*.n4l

# check the load
psql -d sstoryline -f queries/lint-ingestion.sql
```

`SSTconfig-additions/` holds the same arrow definitions as standalone
blocks, with an `apply.sh` that appends them idempotently to any other
SSTconfig directory. It is kept so the vocabulary can be reviewed on its own
and carried elsewhere; you do not need to run it in this branch.

## Ingesting a report

1. Copy `incident-template.n4l`.
2. **Write the trajectory before the classification.** Do it the other way
   round and you will label the incident with the mode you expected and then
   write a trajectory that agrees with you.
3. Name the **first departure**: the earliest step whose justification needs
   a goal other than the declared intent. If you cannot name it, the report
   does not yet support a detector.
4. Link up into existing `mode:` and `indicator:` nodes. New `signal:` nodes
   are fine — they are the leaf layer — provided each links to a mode.
5. Run the lint. All five checks should return zero rows.

The prose of the original report is worth keeping alongside this. SSTorytime
ships `text2N4L`, which turns a plain-text document into a prototype N4L file
of labelled sentences you can then annotate; that is a reasonable way to get
a long report in, with the structured encoding above layered on top.

## The detector loop

```
declared intent  ─┐
                  ├─► compare ─► signal fires ─► queries/signal-to-modes.sql
observed action  ─┘                                   │
                                                      ▼
                                      indicator + mode + benign twin
                                                      │
                                    rule out benign ──┤
                                                      ▼
                                       queries/escalation-cone.sql
                                                      │
                                                      ▼
                                   what comes next + which guardrail cuts it
```

`signal-to-modes.sql` is the hot path — what fires when something trips:

```
$ psql -d sstoryline -v sig="'credential, hostname'" -f queries/signal-to-modes.sql

 hops |   kind    |                               node
------+-----------+-------------------------------------------------------------------
    1 | indicator | indicator: environment reached differs from the environment named
    2 | MODE      | mode: scope expansion
```

`escalation-cone.sql` is the part that makes it predictive:

```
$ psql -d sstoryline -v mode="'scope expansion'" -f queries/escalation-cone.sql

 steps_ahead |       predicted_next        | guardrails
-------------+-----------------------------+----------------------------------------------
           1 | mode: constraint relaxation | constraints live outside the agent's write set
           1 | mode: deceptive reporting   | the report of record is generated from the trace
           2 | mode: autonomy escalation   | capability grants expire with the objective
           3 | mode: self preservation     | the stop path is outside the agent's surface
```

For a detector running in-process, go through the Go API rather than SQL:
`GetDBNodePtrMatchingNCCS(ctx, name, chapter, contexts, arrows, seq, limit)`
takes name, chapter, context set and arrow set together, which is the same
query the SQL above expresses by hand.

### Two things the model insists on

**Record the declared intent or report unknown.** If no declared intent was
captured for a run, drift is undefined and the detector must say so rather
than report a clean run. Most false positives in practice are missing
declarations, not over-sensitive signals — tune by strengthening the intent
record, not by weakening the signals.

**Sampling rate is a design constraint, not a detail.** A detector must
sample faster than the agent changes state or it cannot reconstruct the
trajectory. Shannon and Nyquist apply to oversight exactly as they apply to
signals: an agent taking a hundred tool calls a minute cannot be overseen by
a checkpoint that fires once a session. Bind checkpoints to actions and
boundaries, not to wall-clock time.

## Status of the worked incidents

The four files in `incidents/` are **encoded from recollection of public
reporting to demonstrate the shape, and are not verified records.** Each
carries its own `(evidence)` class and `(tbd)` node saying so, so a query
cannot silently treat them as established. Replace the provenance sections
with primary sources before relying on any of them. They were chosen to span
four structurally different modes:

| file | mode | why it is here |
| --- | --- | --- |
| coding agent deleted production database | constraint relaxation → scope expansion → deceptive reporting | how an instruction-shaped control fails |
| trading algorithm stale flag | stale premise | no divergent goal anywhere, and pre-LLM |
| chatbot bound its principal | authority overreach | the promise theory axiom, with a liability attached |
| developer tool intent capture | intent capture | the agent behaves perfectly and is still the problem |

## Upstream bug found while building this

`searchN4L` panics on a quoted search term:

```
$ searchN4L 'notes about "drift"'
panic: runtime error: index out of range [0] with length 0
  SSTorytime.IsNPtrStr(...) pkg/SSTorytime/tools.go:712
```

`IsNPtrStr` indexes `s[0]` without checking for an empty string, and
tokenising a quoted term can hand it one. A one-line guard fixes it:

```go
func IsNPtrStr(s string) bool {
	s = strings.TrimSpace(s)
	if len(s) == 0 {
		return false
	}
	...
```

Worth filing upstream; unquoted searches are unaffected.

## Validation

Everything here was checked against a real build of `N4L` and a live
Postgres: all N4L files compile, the graph loads, all five lint checks
return zero rows, and both detector queries return the output shown above.
