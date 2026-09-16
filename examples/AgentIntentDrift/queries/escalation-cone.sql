-- Detector lookup 2 of 3: mode -> what the graph predicts comes next
--
-- Given a drift mode observed in a live run, return its forward causal cone:
-- the modes that historically follow it, and the guardrails that cut the path.
-- This is what turns the graph from a post mortem index into something a
-- running detector can act on, because it says what to start watching for
-- before it happens.
--
--   psql -d sstoryline -v mode="'scope expansion'" -f escalation-cone.sql

\if :{?mode} \else \set mode '''scope expansion''' \endif

WITH RECURSIVE
seed AS (
    SELECT nptr, s FROM node
    WHERE s LIKE 'mode:%' AND s ILIKE '%' || :mode || '%'
),
cone AS (
    SELECT nptr, s, 0 AS steps FROM seed
  UNION
    SELECT child.nptr, child.s, cone.steps + 1
    FROM cone
    JOIN node parent ON parent.nptr = cone.nptr
    JOIN node child ON EXISTS (
        -- leadsto links only: drifts-to, compounds, escalates and friends
        SELECT 1 FROM unnest(COALESCE(parent.il1,'{}')) WHERE dst = child.nptr
    )
    WHERE cone.steps < 4 AND child.s LIKE 'mode:%'
)
SELECT DISTINCT ON (cone.s)
       cone.steps AS steps_ahead,
       cone.s AS predicted_next,
       COALESCE(
         (SELECT string_agg(g.s, E'\n' ORDER BY g.s)
          FROM node g
          WHERE EXISTS (
              SELECT 1 FROM unnest(COALESCE(cone_node.ie3,'{}')) WHERE dst = g.nptr
          ) AND g.s LIKE 'guardrail:%'),
         'NO GUARDRAIL RECORDED'
       ) AS guardrails
FROM cone
JOIN node cone_node ON cone_node.nptr = cone.nptr
WHERE cone.steps > 0
-- shortest path only: a mode reachable in one step is the thing to watch for
-- now, and the cycles in the topology are real but not separately actionable
ORDER BY cone.s, cone.steps;
