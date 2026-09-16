# Network fault diagnosis

A differential-diagnosis graph for switching fabrics. The agent's runtime
inputs are an **anomaly report** — events emitted by known playbooks — and
**counters**. The graph's inputs are the four documents an engineer already
has: the architecture document, the ASIC programmer manual, the switch
configs, and previous incident reports.

Given an anomaly report it returns **probable causes, ranked and explained**,
a **counter query plan** to confirm or refute each, and — only if still
ambiguous — the active test that best separates what is left.

The ranking is not the product. The **next observation** is.

## Is SSTorytime a fair fit, and are counters the wrong modality?

**Counters are the wrong modality, and the design keeps them out.** The rule
is: *events are symbols, counters are signals; this library stores symbols.*

Counter **values** never enter the graph. Counter **semantics** always do.
What the graph holds is the predicate — which counter, over which window,
compared against what, and what a true or false reading means for which
hypothesis. The agent compiles that into a telemetry query and runs it
against the real system. The graph never answers *what is the tail drop
count*; it answers *which counter would settle this, over what window, and
what each outcome means*.

Four reasons values do not belong here, each sufficient alone:

| | |
| --- | --- |
| **Cardinality** | thousands of counters × ports × devices would bury the knowledge under millions of nodes |
| **Staleness** | values change per second; N4L upload is slow and the database is used as a consistent cache, not a time-series store |
| **No numeric semantics** | there is no way to express "delta over window exceeds threshold" in N4L. Node text is text |
| **Wrong question** | a graph is for what things *mean*, and a counter value means nothing without its window and baseline |

**Counters also cannot generate hypotheses** — a separate claim, and the one
the query enforces:

* **Free-running.** A nonzero counter proves nothing; it has accumulated
  since boot. Only a delta across a window spanning the anomaly is evidence.
* **Unscoped.** An interface counter aggregates everything that crossed it,
  so it cannot attribute loss to the flow anyone is complaining about.
* **Multiple comparisons.** Scan thousands of counters for anomalies and
  something will always look anomalous. A hypothesis found by scanning has
  no prior and no meaning.

So: **hypotheses are generated from the anomaly report and nothing else.
Counters reweight candidates that events already raised, and may never
introduce one.** That rule is enforced in `queries/probable-cause.sql`, not
left to discipline — it will be under constant pressure from the reasonable-
sounding idea of feeding in more data.

**Where the library genuinely does fit:** fault propagation *is* a process —
mechanism → effect → symptom — which is what `LEADSTO` is for, and diagnosis
is path-finding from symptom back to cause. N4L's context model is described
in the docs as *sensory* input with the user as policy engine, which is
exactly the diagnostic posture. And the anomaly report is the right modality
for a symbol store: discrete, pre-interpreted, scoped to a device and time,
and drawn from a **finite enumerable vocabulary** — the same property that
makes the ASIC drop-reason enumeration so useful.

**Where it does not fit, beyond counters:** there is no inference engine and
no probabilistic semantics. The ranking is a heuristic written on top; the
query header says so at length. A confidently ordered wrong list anchors an
engineer for hours — see `incidents/INC-2411`, nine of eleven hours on
hypothesis one. Hence recall over precision, explicit `confusable` and
`masked-by` relations, and an observation to make instead of a verdict.

## Two phases: the model runs once, offline

```
PHASE 1 -- ONCE PER DOCUMENT, OFFLINE, WITH AN LLM, REVIEWED BY A HUMAN
  plain-English incident reports, design docs, functional specs,
  ASIC manual  ──► LLM extraction ──► N4L ──► graph

PHASE 2 -- EVERY DIAGNOSIS, ONLINE, NO MODEL IN THE LOOP
  complaint ──► agent/diagnose.py ──► ranked hypotheses
                                  ──► executable telemetry plan
```

Users write in plain English. The language model earns its keep exactly
once, turning that prose into N4L, where a human can review the diff before
it lands. At runtime there is no model: `agent/diagnose.py` is standard
library plus `psql`, every decision is a lookup or an integer comparison,
and the same input always produces the same output.

**The consequence, which is easy to miss:** with no model at runtime,
everything the agent needs must be machine-evaluable. "Materially above the
quiet baseline" is LLM-readable, not agent-executable. So extraction has a
second target beyond prose — `layers/60-check-predicates.n4l` — carrying
window in seconds, aggregation, comparison rule and a numeric trigger. The
prose stays for the human reviewing the graph; the predicate is what runs.

A check missing any of those is reported **NOT EVALUABLE** and its
hypothesis stays open, because silently skipping a check turns an unsettled
hypothesis into an apparently excluded one. The same applies one level up: a
hypothesis with no check at all is reported as a gap in the graph, not as a
clean bill of health.

```
$ ./agent/diagnose.py "everything is sluggish today" --answer "comes and goes"

complaint in : 'everything is sluggish today'
matched      : complaint: the network is slow  (lexical overlap 0.67)

--- RANKED HYPOTHESES ---
  [  5] fault: ecmp hash polarisation
        explains 1 symptom(s) = +3
        confirmed 3x before = +3
        covered by playbook: interface congestion which did not fire = -3
        precondition holds = +2

--- TELEMETRY PLAN FOR THE LEADING HYPOTHESIS ---
  * check: transmitted byte spread across ecmp members
      path      : interfaces interface state counters out-octets
      winsec    : 300
      aggregate : delta over window, per member interface
      compare   : max member against min member within the same group
      trigger   : ratio above 4.0 with the minimum member below 10 percent of the maximum
```

Complaint matching is lexical overlap against stored `wording:` variants —
a stopword list and set arithmetic, which is the entire extent of the text
processing at runtime. An unmatched complaint is reported as a **curation
gap**, not guessed at: it is a wording worth adding, which is a job for a
human and an LLM, offline, where it belongs.

## Is this a reasoning engine? No — and that is the point

A fair reading of this library is *an LLM's associative memory without the
reasoning mode*. It stores typed relations and traverses them. It has no
inference engine, no forward chaining, no constraint solver, no probabilistic
update. Everything that looks like reasoning in `queries/` is SQL I wrote.

But that is the correct division of labour here, because you already have a
reasoner: the agent. What the agent lacks is a substrate that keeps it
honest. Against an LLM's own associations, this graph gives four things:

| | |
| --- | --- |
| **Citable** | every edge was written by a person from a named document, and `source:` travels with the answer |
| **Deterministic** | same query, same answer. No sampling |
| **Cannot fabricate** | if the edge is not there you get nothing, rather than something plausible |
| **Computably incomplete** | `blind-spots.sql` answers "what can this system not know?" — a question you cannot put to a model |

So: **the graph is the memory, the agent is the reasoner, and the graph's job
is to bound what the agent may assert.** A hypothesis that is not in the
graph should not reach the operator; a step in a debug script that cannot
cite a document should not be run.

## Is a guided debug script feasible with what the library provides?

Yes, and it is arguably the most idiomatic thing you can build on it.
Semantic Spacetime is a library about **stories** — paths through a graph —
and a debug script *is* a story: complaint, hypothesis, observation, branch,
next observation. That is a path, and paths are the one thing this database
is actually built for.

`queries/debug-script.sql` emits one. Every field in its output is a stored
fact retrieved and ordered — nothing is inferred:

```
$ make script HYP="ecmp hash polarisation"

=== STEP CLASS 0 : DESK CHECKS (no device touched) ===
 precondition: more than one equal cost path exists between the endpoints | status: precondition holds
 precondition: the hash seed is identical across tiers                    | status: precondition holds

=== STEP CLASS 1 : PASSIVE TELEMETRY (guided by counter schema) ===
 step        | 2
 observation | transmitted byte spread across ecmp members
 read_path   | interfaces interface state counters out-octets
 how_to_read | cumulative counter, free running, meaningful only as a delta
 at_scope    | per interface
 over_window | the interval spanning the reported anomaly, per member interface
 if_true     | sustained spread far beyond flow count variance, one member near idle
 if_false    | members within normal spread of each other
 caveat      | separates polarisation from every other congestion cause
```

Steps are ordered by cost — desk checks that touch no device, then passive
telemetry, then active tests — and within a class the checks that are
decisive in *both* directions come first, because those end the branch either
way. The `read_path` comes from `layers/50-counter-schema.n4l`, which is what
makes the telemetry **guided** rather than advisory: the agent gets a path,
a scope and a reading rule it can execute, not a sentence to interpret.

**What the library does not give you, and I had to build:** the ordering
heuristic, the scoring, anything numeric or temporal (windows and thresholds
are text the agent must interpret), and execution. It emits the script; it
cannot run it.

## The complaint is the entry point, and silence is the evidence

A playbook exists because someone could already characterise the problem with
counters, and it already carries remediation. **So a complaint that reaches a
human is, by selection, one the playbooks did not catch.** That inverts the
usual assumption: the absence of a matching event is not missing information,
it is the strongest single signal available, and it points *away* from
everything the playbook library covers.

Hence `complaint-model.n4l`, which narrows "my network is slow" by asking the
cheapest question that most divides the space — history taking, not
measurement — and hence the scoring rule that **promotes** faults no playbook
covers and **demotes** faults whose playbook stayed silent.

Demoted, never eliminated. A playbook can be scoped to the wrong devices, or
its threshold can sit above what a user notices. A user perceives a two
second stall; the congestion playbook needs five minutes. That band is where
complaints live, so every demotion is reported with its escape hatch: which
playbook covers this, at what threshold, and could the complaint be below it.

In the worked fabric, two faults are covered by no playbook at all —
`mtu mismatch on a transit hop` and `cabling or patch error`. Those are the
prime suspects for any unexplained complaint, and that ranking falls directly
out of your own playbook library rather than being asserted by me.

## The pipeline

```
vague complaint ──► cheapest narrowing question ──► symptoms
"my network is slow"                                    │
                     anomaly report, if any ────────────┤
                        (symbols)                       ▼
                                                 candidate faults
                                                        │
                                    prune by precondition (config)
                                    expand by confusability (recall)
                                                        │
                                                        ▼
                                          COUNTER QUERY PLAN
                                     (confirm / exclude, with window)
                                                        │
                                            still ambiguous?
                                                        ▼
                                          active discriminating test
```

## Layout

```
fault-model.n4l       curated causal knowledge. Changes rarely
layers/               GENERATED from your documents. Changes with the network
  10-design-intent      architecture document
  20-asic-facts         ASIC manual: drop codes, capacities, counter semantics
  30-config-facts       configs: values and which preconditions hold here
  40-event-playbooks    the playbook event vocabulary and its symptom mapping
incidents/            one file per prior incident: priors, real wording, tests
queries/              probable-cause.sql, blind-spots.sql
```

`fault-model.n4l` is hand-curated; `layers/` is generated. Mixing them is how
a graph like this rots. Keeping the event-to-symptom mapping in the layer
rather than the model is the same split: playbooks change often, knowledge
about how fabrics fail does not, so a new playbook adds a mapping and touches
nothing else.

## Five relations carry the diagnostic weight

* **`manifests`** — cause to symptom. Diagnosis walks it backwards.
* **`describe`** — event to symptom. The join between the machine feed and
  the causal model.
* **`confusable`** — these present identically at the level people look
  first. The only reason the worked example finds the right answer.
* **`masked-by`** — why an expected symptom can be *absent* while the cause
  is present. Without it a query silently rules out the true cause.
* **`confirms` / `excludes`** — a counter check against the hypotheses a true
  reading settles. Note that one check can confirm two faults; the model says
  so rather than letting it be read as pointing at the first.

## Worked example

`incidents/INC-2411`: intermittent inter-rack loss, healthy average
utilisation, correlated with a batch job. Eleven hours to resolve, nine on a
failing-optic theory. Root cause was ECMP hash polarisation, both tiers on
the vendor default hash seed — a divergence from a design requirement written
specifically to prevent it, visible in the config the whole time.

Feeding in the anomaly report as the playbooks would emit it:

```
$ make diagnose EVENTS="sustained egress queue drops,inter rack probe loss"

===== 2. CANDIDATES, GENERATED FROM EVENTS ONLY =====
                      fault                       |      origin       | sympt | priors |       precondition       | score
--------------------------------------------------+-------------------+-------+--------+--------------------------+-------
 fault: buffer exhaustion from microbursts        | observed          |     2 |      2 | possible here            |    10
 fault: ecmp hash polarisation                    | via confusability |     0 |      3 | possible here            |     5
 fault: overlay to underlay mapping inconsistency | observed          |     1 |      0 | possible here            |     5
 fault: mtu mismatch on a transit hop             | via confusability |     0 |      0 | RULED UNLIKELY by config |    -4
```

The true cause explains **none** of the reported events. It surfaces only
through a confusability link — a precision-oriented tool would not have
listed it at all. Meanwhile the config layer demotes the MTU hypothesis
without deleting it, because config can be stale.

Then the decisive part, which is one passive counter read:

```
===== 3. CONFIRM WITH THESE COUNTER READS =====
      hypothesis            |      effect      |            counter_check
----------------------------+------------------+--------------------------------------
 buffer exhaustion          | EXCLUDES if true | transmitted byte spread across ecmp members
 ecmp hash polarisation     | confirms if true | transmitted byte spread across ecmp members
   read_this:    counter: per interface transmitted bytes
   over_window:  the interval spanning the reported anomaly, per member interface
   caveat:       separates polarisation from every other congestion cause
```

One counter, one window, and it resolves the top two in opposite directions.
That is what counters are for. Note the tail-drop check is also offered and
carries an explicit caveat that it confirms *congestion* without identifying
*which* congestion cause — which is precisely how nine hours get spent.

## Playbook coverage

Because hypotheses come only from events, a fault whose every symptom lacks
an emitting playbook is invisible to the agent no matter how good its
reasoning. `queries/blind-spots.sql` finds them:

```
$ make blindspots

===== 1. FAULTS NO PLAYBOOK CAN EVER SURFACE =====
    invisible_fault     |   severity   |  unreachable_symptoms
------------------------+--------------+------------------------------------------
 cabling or patch error | impact: high | neighbour discovery is asymmetric between the two ends
                        |              | the problem affects one device and its peers are fine
```

Each row is a playbook worth writing, ranked by the severity of what it would
make visible. Section 2 lists partially covered faults, which will rank lower
than they deserve whenever the uncovered tell is the one that actually fired;
section 3 lists events that resolve to nothing, which are playbooks firing
into a model that cannot reason about them.

This is the query to run when someone asks why the agent missed something.

## Running it

```sh
make                                             # load model, layers, incidents
make diagnose EVENTS="routing adjacency reset"   # rank causes from an anomaly report
make blindspots                                  # playbook coverage analysis
```

## Status

The fabric, configs, ASIC facts, playbook vocabulary and incident here are
**synthetic** — a plausible leaf-spine example to demonstrate the shape. Real
capacities, drop codes and counter names must come from your actual silicon's
manual; the ones here are illustrative and are not facts about any real ASIC.

Validated against this checkout with a live Postgres: everything compiles,
the graph loads (255 nodes), and every query output shown above is real.
