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

## The pipeline

```
anomaly report ──► resolve events to symptoms ──► candidate faults
   (symbols)                                            │
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
