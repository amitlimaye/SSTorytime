# Network fault diagnosis

A differential-diagnosis graph for switching fabrics. Inputs are the four
documents an engineer already has — the architecture document, the ASIC
programmer manual, the switch configs, and previous incident reports —
merged into one SST graph. Given observed symptoms it returns **probable
causes, ranked and explained**, and then the single test that best separates
the top hypotheses.

The ranking is not the product. The **next test** is.

## Is SSTorytime a fair fit for this?

Honestly: **yes for the causal half, no for the data half**, and the design
below draws that line deliberately rather than pretending it isn't there.

**Where the fit is genuinely good**

* Fault propagation *is* a process — mechanism leads to effect leads to
  symptom. That is what `LEADSTO` is for, and SSTorytime is explicitly built
  around processes rather than taxonomies. Diagnosis is path-finding from
  symptom back to cause, which is the operation this database is best at.
* N4L's context model is described in the docs as *sensory* input, with the
  user as the policy engine deciding relevance. That is exactly the
  diagnostic situation: counters and symptoms are the sensory feed, and the
  engineer decides what matters. The tool's own framing fits the problem.
* Merging heterogeneous curated documents into one searchable web is the
  stated use case, and four document classes with different authority is
  precisely that problem.

**Where it is a poor fit, and what this example does about it**

* **There is no inference engine and no probabilistic semantics.** Links
  carry a weight and there is eigenvector centrality, but nothing here is
  Bayesian. The ranking in `queries/probable-cause.sql` is a heuristic *I*
  wrote on top of the graph. The graph supplies recall and explanation; it
  does not supply likelihood, and the query header says so at length.
* **Configs and counters are structured data, not notes.** Hand-curating a
  graph of every config line would drown the causal knowledge that gives
  this thing its value. So `layers/` is generated, `fault-model.n4l` is
  curated, and the two never mix.
* **ASIC manuals are far too large to ingest.** The docs already warn that
  `text2N4L` on a book takes hours and produces mostly noise. Three short
  extracts earn their place: drop reason codes, table capacities per
  forwarding profile, counter semantics.
* **Counter values must not be in the graph at all.** It holds what a counter
  *means*. Values come from the live device at query time.

**The real risk, stated plainly.** A confidently ordered list of probable
causes can anchor an engineer on the wrong hypothesis for hours — see
`incidents/INC-2411`, where nine of eleven hours went to hypothesis one. A
tool that produces a better-looking wrong list makes that worse, not better.
That is why the model optimises for **recall over precision**, carries
explicit *confusability* and *masking* relations, and ends every answer with
a discriminating test instead of a verdict.

## Layout

```
fault-model.n4l    curated causal knowledge. Changes rarely
layers/            GENERATED from your four documents. Changes with the network
incidents/         one file per prior incident: priors, real symptom sets, tests
queries/           the probable-cause ranker
SSTconfig-additions/  arrow vocabulary, already applied to SSTconfig on this branch
```

## Where each document does its work

| document | supplies | how it is used in diagnosis |
| --- | --- | --- |
| architecture document | design intent and requirements | makes a config value *wrong* rather than merely unusual |
| ASIC programmer manual | drop codes, table capacities, counter semantics | turns "packets are being lost" into a **bounded** question — the drop reason enumeration is a finite set |
| switch config | configured values, precondition status | **prunes** hypotheses that are not possible in this fabric |
| prior incidents | priors, real symptom wording, confusability | teaches the graph what looks like what — learned by having been wrong |

## Four relations that carry the diagnostic weight

* **`manifests`** — cause to symptom. Diagnosis walks it backwards.
* **`confusable`** — these present identically at the level people look
  first. This is what makes a test worth running, and it is the only reason
  the worked example below finds the right answer.
* **`masked-by`** — why an expected symptom can be absent while the cause is
  present. Without it a query silently rules out the true cause, which is the
  worst thing a diagnostic tool can do.
* **`discriminates`** — a test against the causes it separates. The output.

## Worked example

`incidents/INC-2411` is a real-shaped incident: intermittent inter-rack loss,
no error counters, healthy average utilisation, correlated with a batch job.
Eleven hours to resolve, nine of them on a failing-optic theory. Root cause
was ECMP hash polarisation, with both tiers left on the vendor default hash
seed — a divergence from a design requirement written specifically to prevent
it, sitting visible in the config the whole time.

Feeding in **only the symptoms as they were originally reported**:

```
$ psql -d sstoryline \
    -v symptoms="'intermittent loss,average interface utilisation,batch job'" \
    -f queries/probable-cause.sql

                   fault                   |      origin       | sympt | priors | precondition  | score
-------------------------------------------+-------------------+-------+--------+---------------+-------
 fault: buffer exhaustion from microbursts | observed          |     3 |      2 | possible here |    13
 fault: ecmp hash polarisation             | via confusability |     0 |      3 | possible here |     5
```

Note what happened. The reported symptoms point entirely at microbursts —
polarisation explains **none** of them, and a precision-oriented tool would
not have listed it. It surfaces only because it is marked confusable with the
top candidate. That is the recall-over-precision choice doing its job, and it
is the whole reason the true cause appears at all.

Then the part to act on:

```
================= RUN THIS NEXT =================
 test                                                  | separates | between_these
-------------------------------------------------------+-----------+---------------------------------------
 compare per interface utilisation across members of   |         2 | buffer exhaustion | ecmp polarisation
 the same ecmp group                                   |           |
   how: read transmitted byte counters for every member interface over the same interval
```

That is the test that actually settled INC-2411 — recommended first, because
it is the one that separates the top two hypotheses rather than the one that
confirms the leading one. Confirming the leader is how you spend nine hours.

## Running it

```sh
make            # load model, layers and incidents
make diagnose SYMPTOMS="intermittent loss,batch job"
```

## Status

The fabric, configs, ASIC facts and incident in this directory are
**synthetic** — a plausible leaf-spine example to demonstrate the shape.
Real capacities, drop codes and counter names must come from your actual
silicon's manual; the ones here are illustrative and should not be trusted
as facts about any real ASIC.

Validated against this checkout with a live Postgres: everything compiles,
the graph loads (188 nodes), and the query output above is real, not
illustrative.
