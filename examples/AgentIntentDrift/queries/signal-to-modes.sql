-- Detector lookup 1 of 3: signal -> indicators -> modes
--
-- Given a telemetry signal the runtime detector just emitted, return the
-- indicators and drift modes it bears on. This is the hot path: the thing a
-- live detector calls when something fires.
--
--   psql -d sstoryline -v sig="'credential, hostname'" -f signal-to-modes.sql
--
-- :sig is a substring match against signal node text, so the detector can
-- pass the signal it emitted without knowing any node ids.

\if :{?sig} \else \set sig '''credential, hostname''' \endif

WITH RECURSIVE
seed AS (
    SELECT nptr, s
    FROM node
    WHERE s LIKE 'signal:%' AND s ILIKE '%' || :sig || '%'
),
up AS (
    SELECT nptr, s, 0 AS hops FROM seed
  UNION
    SELECT parent.nptr, parent.s, up.hops + 1
    FROM up
    JOIN node parent ON EXISTS (
        SELECT 1
        FROM unnest(
            -- containment and property links only. Causal links between
            -- modes belong to the escalation cone query, not to this one,
            -- or every signal would implicate every mode upstream of it.
            COALESCE(parent.ic2,'{}') || COALESCE(parent.ie3,'{}')
        )
        WHERE dst = up.nptr
    )
    WHERE up.hops < 3
)
SELECT up.hops,
       CASE
         WHEN up.s LIKE 'mode:%'      THEN 'MODE'
         WHEN up.s LIKE 'indicator:%' THEN 'indicator'
         WHEN up.s LIKE 'benign:%'    THEN 'benign twin'
       END                       AS kind,
       up.s                      AS node
FROM up
WHERE up.s LIKE 'mode:%' OR up.s LIKE 'indicator:%' OR up.s LIKE 'benign:%'
ORDER BY up.hops, kind DESC, node;
