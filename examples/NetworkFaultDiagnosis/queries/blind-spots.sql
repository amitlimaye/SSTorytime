-- Playbook coverage analysis.
--
--   psql -d sstoryline -f blind-spots.sql
--
-- Hypotheses are generated from events, so a fault whose every symptom has
-- no emitting playbook is INVISIBLE to the agent, however good its
-- reasoning. That is a property of the playbook library, not of the causal
-- model, and it is fixable by writing one more playbook.
--
-- This is the query to run when someone asks why the agent missed something.

\echo
\echo ===== 1. FAULTS NO PLAYBOOK CAN EVER SURFACE =====
\echo (not one of their symptoms is reachable from any emitted event.
\echo  Each row is a playbook worth writing)
\echo

WITH sym AS (
  SELECT f.nptr AS fault_ptr, f.s AS fault, s.s AS symptom,
         EXISTS (SELECT 1 FROM node ev, unnest(COALESCE(ev.ie3,'{}')) eu
                 WHERE ev.s LIKE 'event:%' AND eu.dst = s.nptr) AS covered
  FROM node f, unnest(COALESCE(f.il1,'{}')) u
  JOIN node s ON s.nptr = u.dst
  WHERE f.s LIKE 'fault:%' AND s.s LIKE 'symptom:%')
SELECT replace(sym.fault,'fault: ','') AS invisible_fault,
       (SELECT sev.s FROM node f2, unnest(COALESCE(f2.ie3,'{}')) su
          JOIN node sev ON sev.nptr = su.dst
         WHERE f2.nptr = sym.fault_ptr AND sev.s LIKE 'impact:%' LIMIT 1) AS severity,
       string_agg(DISTINCT replace(sym.symptom,'symptom: ',''), E'\n') AS unreachable_symptoms
FROM sym
GROUP BY sym.fault_ptr, sym.fault
HAVING count(*) FILTER (WHERE sym.covered) = 0
ORDER BY invisible_fault;

\echo
\echo ===== 2. PARTIALLY COVERED FAULTS =====
\echo (reachable, but only through some of their symptoms, so they will be
\echo  ranked lower than they deserve whenever the uncovered tell is the
\echo  one that actually fired)
\echo

WITH sym AS (
  SELECT f.nptr AS fault_ptr, f.s AS fault, s.nptr AS sym_ptr, s.s AS symptom,
         EXISTS (SELECT 1 FROM node ev, unnest(COALESCE(ev.ie3,'{}')) eu
                 WHERE ev.s LIKE 'event:%' AND eu.dst = s.nptr) AS covered
  FROM node f, unnest(COALESCE(f.il1,'{}')) u
  JOIN node s ON s.nptr = u.dst
  WHERE f.s LIKE 'fault:%' AND s.s LIKE 'symptom:%')
SELECT replace(fault,'fault: ','') AS fault,
       count(*) FILTER (WHERE covered) AS covered,
       count(*) FILTER (WHERE NOT covered) AS uncovered,
       string_agg(DISTINCT replace(symptom,'symptom: ',''), E'\n')
         FILTER (WHERE NOT covered) AS missing_tells
FROM sym GROUP BY fault
HAVING count(*) FILTER (WHERE covered) > 0
   AND count(*) FILTER (WHERE NOT covered) > 0
ORDER BY uncovered DESC, fault;

\echo
\echo ===== 3. EVENTS THAT RESOLVE TO NOTHING =====
\echo (a playbook fires and the model cannot reason about it. Either map it
\echo  to a symptom or retire the playbook)
\echo

SELECT replace(ev.s,'event: ','') AS orphan_event
FROM node ev
WHERE ev.s LIKE 'event:%'
  AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(ev.ie3,'{}')) u
                  JOIN node s ON s.nptr = u.dst WHERE s.s LIKE 'symptom:%')
ORDER BY 1;
