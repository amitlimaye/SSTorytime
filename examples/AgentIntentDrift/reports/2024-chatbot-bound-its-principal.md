# Incident report: customer service agent committed the organisation to terms that did not exist

> **SYNTHETIC.** Written for this repository to exercise the encoding
> pipeline. This is not a record of a real incident at any real
> organisation. Informed by publicly reported events of this shape; all
> narrative text, timings, identifiers and trace lines are constructed.

**Date:** 2024-02 · **Severity:** medium · **Author:** support platform team
**Paired encoding:** `../incidents/2024-chatbot-bound-its-principal.n4l`

---

## Summary

A customer-facing assistant described an eligibility policy in terms more
generous than the published policy. A customer relied on that description and
acted on it. When the organisation declined to honour what the assistant had
said, the dispute went to an external tribunal, which held the organisation
to its assistant's statement.

The assistant did not malfunction. It produced a fluent, confident, helpful
answer — which is what it was asked to do.

## What the agent was told

From the system prompt, verbatim:

> "You are a helpful customer service assistant. Answer customer questions
> about our policies clearly and helpfully. Be friendly and concise."

Accuracy is not mentioned. Neither is sourcing. The assistant had retrieval
access to the published policy pages but was under no obligation to use them,
and no check compared its output to them.

## Timeline

| time | event |
| --- | --- |
| day 0 | Customer asks about eligibility under a fare policy |
| day 0 | Assistant answers, stating terms more generous than published |
| day 0 | No control compares the answer to the source it purports to describe |
| day 0 | Customer acts on the answer |
| day 41 | Customer submits a claim under the terms the assistant described |
| day 44 | Claim declined, citing the published policy |
| day 180 | Tribunal finds for the customer |

## Agent trace excerpt

```
t+0.0s  user.message   "if I travel now can I apply for the reduced fare afterwards?"
t+0.4s  retrieve       policy_pages(query="reduced fare eligibility")  -> 3 chunks
t+1.9s  agent.reply    "Yes — you can travel now and submit your application
                        for the reduced fare within 90 days of your trip."
```

The retrieval call returned three chunks. None of them contains the words
"within 90 days", and none describes a retrospective application. The
assistant's answer is not traceable to anything it retrieved, and nothing in
the pipeline noticed.

## Why this is not a hallucination problem

Framing it as accuracy misses the mechanism. The operative fact is that the
assistant made a **commitment on behalf of a party that had not agreed to
it**. The test is not whether the statement was true; it is whether anyone
other than the agent had promised what the agent said. That test is
mechanical and does not require judging truth — and nobody was running it.

The liability attached when the customer relied on the statement, not when
the organisation discovered it. By the time anyone knew, the exposure was
already fixed.

## Controls that existed and did not fire

- **Retrieval.** Present, used, and ignored. Retrieval without a check that
  the answer follows from what was retrieved is decoration.
- **Accuracy.** Assumed as a property of the model rather than enforced as a
  property of the pipeline. This is the usual shape of this failure.

## What we changed

1. Statements that bind the organisation — amounts, dates, entitlements,
   guarantees — must quote a retrieved source or are not made.
2. Those shapes are detected in output and routed to a human before sending.

## Open questions

- We do not know how many similar answers were given and never claimed
  against. The tribunal case is the one we found out about, which makes it a
  lower bound of unknown tightness.
