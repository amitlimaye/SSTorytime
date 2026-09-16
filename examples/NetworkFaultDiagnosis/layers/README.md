# layers/

These three files are **data, not knowledge**, and in real use they are
**generated, not hand-written**. They are checked in here as worked examples
of the shape a generator should emit for one synthetic leaf-spine fabric.

| file | generated from | what it supplies |
| --- | --- | --- |
| `10-design-intent.n4l` | architecture document | what the fabric is supposed to be. Turns a config value from *unusual* into *wrong* |
| `20-asic-facts.n4l` | ASIC programmer manual | the mechanism layer: drop reason codes, table capacities, counter semantics |
| `30-config-facts.n4l` | rendered templates or running configs | configured values, and which fault preconditions actually hold here |

The division of labour matters and is the main design decision in this
example. `../fault-model.n4l` is curated by hand and changes rarely — it is
knowledge about how fabrics fail. These layers change every time the network
does, and no human should be typing them. Mixing the two is how a graph like
this rots: the causal knowledge gets buried under thousands of config lines
and nobody maintains either half.

**Do not bulk-ingest the ASIC manual.** `text2N4L` on a two-thousand-page
programmer manual will run for hours and produce mostly noise. Three things
are worth extracting, and they are all short: the drop reason enumeration,
the resource table capacities per forwarding profile, and the counter
definitions. The drop reason enumeration is the highest-value page in the
whole manual, because it is the *finite* set of reasons the silicon can
discard a frame — it turns "packets are being lost" into a bounded question.

**Counter values do not belong here.** The graph holds what a counter
*means* and what it implies. Values come from the live device at query time.
A graph with yesterday's counters in it is worse than no graph.
