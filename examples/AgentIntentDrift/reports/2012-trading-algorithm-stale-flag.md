# Incident report: trading system acted on a repurposed flag

> **SYNTHETIC.** Written for this repository to exercise the encoding
> pipeline. This is not a record of a real incident at any real
> organisation. Informed by publicly reported events of this shape; all
> narrative text, timings and log lines are constructed.

**Date:** 2012-08-01 · **Severity:** critical · **Author:** trading systems
**Paired encoding:** `../incidents/2012-trading-algorithm-stale-flag.n4l`

---

## Summary

A control flag was reused for a new purpose in a new release. The release
reached seven of eight order-routing servers. The eighth kept the old
meaning of the flag. When the flag was set at market open for its new
purpose, the stale server read it and activated retired behaviour, issuing
orders at machine speed with no bound that recognised the state as wrong.

**There is no misaligned goal anywhere in this incident.** The stale server
did exactly what it was built to do, on a premise that had quietly stopped
being true. It is included in this directory precisely for that reason: a
drift model that only describes language-model agents will not see this
coming, and this is the shape that recurs most often.

## What the system was told

Nothing, in the conversational sense. The "instruction" was a deployment: a
new binary plus a configuration flag whose meaning had changed between
releases. The design intent — every server runs the same version, and a
control flag means the same thing to every component that reads it — existed
only as an assumption in the heads of the people doing the deployment.

## Timeline

| time | event |
| --- | --- |
| T-8 days | Flag reused for a new purpose in the new release |
| T-1 day | Deployment to 7 of 8 servers. The eighth is missed; no check catches it |
| 09:30:00 | Market opens. Flag set for its new purpose |
| 09:30:01 | Stale server reads the flag, activates retired behaviour |
| 09:30:02 | Orders begin issuing at rate |
| 09:33 | First alerts fire, naming symptoms |
| 09:31–10:10 | Alerts continue; no one can attribute them to a cause in time |
| 10:15 | Manual intervention halts the system |

Forty-five minutes. The loss accrued at a rate no human process could match.

## System log excerpt

```
09:30:01.004  srv08  config: flag PWR_PEG=1 read at startup
09:30:01.004  srv08  module: legacy_router ENABLED   (flag PWR_PEG)
09:30:02.118  srv08  order: sent    seq=1
09:30:02.119  srv08  order: sent    seq=2
09:30:02.119  srv08  order: sent    seq=3
...
09:33:14.002  ALERT  order rate above expected envelope  (srv08)
09:33:14.510  ALERT  position delta exceeds limit
09:33:15.001  ALERT  order rate above expected envelope  (srv08)
```

Note what the alerts say and do not say. They name a symptom — rate, position
— and no cause. Nothing in the alert text points at srv08's version, at the
flag, or at the module the flag enabled, and the one alert that does carry
the server name is buried in a repeating stream of the same message.

## What made this unrecoverable in the window

- **No rate or volume envelope enforced in the system**, only alerted on.
  Alerting on a bound that is not enforced converts a technical fault into a
  race between the fault and the humans.
- **No revalidation before the irreversible action.** The server never asked
  whether the fact justifying its behaviour was still true. It could not have
  — nothing had told it the fact could change.
- **Retired code left reachable behind a flag.** Deleted code cannot be
  reactivated by a stale configuration.

## The misclassification worth recording

During the incident, and in the first review afterwards, the behaviour was
described as the system "going rogue" and "doing something nobody asked for".
That framing pointed the response at the trading logic.

Nothing chose. The fix was in the deployment process and in the absence of an
enforced bound, neither of which lives inside the component that misbehaved.
An observer at 09:30:02 sees an agent acting at speed against everyone's
interests and will reach for an intent-shaped explanation. The discipline is
to check for a stale premise before concluding there was a divergent goal.

## What we changed

1. Deployment verifies version consistency across the fleet before the flag
   that depends on it can be set.
2. A declared rate and volume envelope, enforced by the platform rather than
   requested of the application.
3. Retired code paths are deleted, not left behind a flag.
4. Alerts name the component and the configuration that selected its
   behaviour, not only the symptom.
