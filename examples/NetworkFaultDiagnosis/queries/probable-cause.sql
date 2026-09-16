-- Probable cause from an anomaly report.
--
--   psql -d sstoryline \
--     -v events="'sustained egress queue drops,inter rack probe loss'" \
--     -f probable-cause.sql
--
-- :events is a comma separated list of substrings matched against the
-- playbook event vocabulary, so the agent can pass the anomaly report
-- through with no translation.
--
-- ---------------------------------------------------------------------
-- THE GENERATION RULE, ENFORCED HERE RATHER THAN BY DISCIPLINE
--
-- Candidates are generated from EVENTS ONLY. Counters appear in section 3
-- as confirmation checks against candidates that events already raised.
-- No counter can introduce a candidate.
--
-- This is not fussiness. A fabric exposes thousands of counters, so
-- scanning them for anomalies guarantees false positives by multiple
-- comparisons alone; a nonzero counter is free running and proves nothing
-- without a delta; and an interface counter is an aggregate that cannot
-- attribute loss to the flow anyone is complaining about. Counters are
-- evidence about a hypothesis, never a source of one.
--
-- Note also what this file does NOT do: it never reads a counter value.
-- It emits the predicate -- which counter, which window, what a true and
-- a false reading mean -- and the agent compiles that into a telemetry
-- query. Values live in the telemetry system. The graph holds meaning.
-- ---------------------------------------------------------------------
--
-- The ranking is a transparent heuristic, not a posterior:
--   3 per observed symptom explained, +1 per confirmed prior occurrence,
--   +2 if the precondition holds here, -4 if the config says it cannot.
-- The honest reading of a rank is "how much of what was reported would
-- this explain", not "how likely is this".

\if :{?events} \else \set events '''sustained egress queue drops,inter rack probe loss''' \endif

\set QUIET on
CREATE TEMP VIEW observed_event AS
  SELECT DISTINCT n.nptr, n.s
  FROM node n, unnest(string_to_array(:events, ',')) AS term
  WHERE n.s LIKE 'event:%' AND n.s ILIKE '%' || btrim(term) || '%';

-- Events resolve to the symptom wording the causal model reasons in.
CREATE TEMP VIEW observed AS
  SELECT DISTINCT sym.nptr, sym.s
  FROM observed_event e
  JOIN node en ON en.nptr = e.nptr,
       unnest(COALESCE(en.ie3,'{}')) u
  JOIN node sym ON sym.nptr = u.dst
  WHERE sym.s LIKE 'symptom:%';

CREATE TEMP VIEW direct AS
  SELECT f.nptr, f.s AS fault, count(DISTINCT o.nptr) AS explains
  FROM node f
  JOIN observed o ON EXISTS (
      SELECT 1 FROM unnest(COALESCE(f.il1,'{}')) WHERE dst = o.nptr)
  WHERE f.s LIKE 'fault:%'
  GROUP BY f.nptr, f.s;

-- Recall over precision: a fault confusable with a direct candidate is
-- pulled in even though it explains nothing, because "presents identically
-- at the level you looked first" is exactly when the report misleads.
CREATE TEMP VIEW candidate AS
  SELECT nptr, fault, explains, 'observed'::text AS origin FROM direct
  UNION
  SELECT n.nptr, n.s, 0, 'via confusability'
  FROM node n
  WHERE n.s LIKE 'fault:%' AND n.nptr NOT IN (SELECT nptr FROM direct)
    AND EXISTS (SELECT 1 FROM direct d JOIN node df ON df.nptr = d.nptr,
                unnest(COALESCE(df.in0,'{}')) u WHERE u.dst = n.nptr);

CREATE TEMP VIEW prop AS
  SELECT f.nptr AS fault_ptr, t.s AS val
  FROM node f, unnest(COALESCE(f.ie3,'{}')) u
  JOIN node t ON t.nptr = u.dst
  WHERE f.s LIKE 'fault:%';
\set QUIET off

\echo
\echo ===== 1. ANOMALY REPORT IN, RESOLVED TO SYMPTOMS =====
SELECT e.s AS event, o.s AS resolves_to
FROM observed_event e
JOIN node en ON en.nptr = e.nptr, unnest(COALESCE(en.ie3,'{}')) u
JOIN node o ON o.nptr = u.dst
WHERE o.s LIKE 'symptom:%' ORDER BY e.s, o.s;

\echo
\echo ===== 2. CANDIDATES, GENERATED FROM EVENTS ONLY =====
WITH scored AS (
  SELECT c.nptr, c.fault, c.explains, c.origin,
    (SELECT (regexp_match(p.val,'([0-9]+) time'))[1]::int FROM prop p
      WHERE p.fault_ptr=c.nptr AND p.val LIKE 'prior:%'
        AND p.val LIKE '%confirmed root cause%' LIMIT 1) AS priors,
    (SELECT st.s FROM node pre, unnest(COALESCE(pre.ie3,'{}')) pu
       JOIN node st ON st.nptr=pu.dst
      WHERE pre.s LIKE 'precondition:%' AND st.s LIKE 'status:%'
        AND EXISTS (SELECT 1 FROM prop p2 WHERE p2.fault_ptr=c.nptr AND p2.val=pre.s)
      ORDER BY st.s LIMIT 1) AS precond
  FROM candidate c)
SELECT fault, origin, explains AS sympt, COALESCE(priors,0) AS priors,
  CASE WHEN precond LIKE '%does not hold%' THEN 'RULED UNLIKELY by config'
       WHEN precond LIKE '%holds%' THEN 'possible here' ELSE 'unknown' END AS precondition,
  explains*3 + COALESCE(priors,0)
    + CASE WHEN precond LIKE '%does not hold%' THEN -4
           WHEN precond LIKE '%holds%' THEN 2 ELSE 0 END AS score
FROM scored ORDER BY score DESC, fault;

\echo
\echo ===== 3. CONFIRM WITH THESE COUNTER READS =====
\echo (a query plan for the telemetry system, not a reading. Counters can
\echo  reweight these candidates; they cannot add one)
\echo
WITH chk_link AS (
  -- Link the check to the fault AND keep the arrow, because the arrow is
  -- what says whether a true reading confirms the hypothesis or kills it.
  SELECT n.nptr AS chk_ptr, n.s AS chk_s, l.dst AS fault_ptr, l.arr
  FROM node n, unnest(COALESCE(n.im1,'{}') || COALESCE(n.il1,'{}')) l
  WHERE n.s LIKE 'check:%'
)
SELECT replace(c.fault,'fault: ','')            AS hypothesis,
       CASE WHEN a.short = 'excludes' THEN 'EXCLUDES if true'
            ELSE 'confirms if true' END          AS effect,
       replace(chk.s,'check: ','')               AS counter_check,
       (SELECT ct.s FROM unnest(COALESCE(chk.ie3,'{}')) cu
          JOIN node ct ON ct.nptr = cu.dst
         WHERE ct.s LIKE 'counter:%' LIMIT 1)    AS read_this,
       (SELECT w.s FROM unnest(COALESCE(chk.ie3,'{}')) wu
          JOIN node w ON w.nptr = wu.dst
         WHERE w.s LIKE 'window:%' LIMIT 1)      AS over_window,
       (SELECT st.s FROM unnest(COALESCE(chk.ie3,'{}')) su
          JOIN node st ON st.nptr = su.dst
         WHERE st.s LIKE 'strength:%' LIMIT 1)   AS caveat
FROM candidate c
JOIN chk_link cl ON cl.fault_ptr = c.nptr
JOIN node chk ON chk.nptr = cl.chk_ptr
JOIN arrowdirectory a ON a.arrptr = cl.arr
WHERE a.short IN ('confirms','excludes')
ORDER BY hypothesis, effect DESC, counter_check;

\echo
\echo ===== 4. WHY AN EXPECTED SYMPTOM MAY BE ABSENT =====
\echo (a missing symptom does not rule a cause out if something masks it)
\echo
SELECT replace(c.fault,'fault: ','') AS hypothesis, m.s AS masked_by
FROM candidate c JOIN node f ON f.nptr=c.nptr, unnest(COALESCE(f.il1,'{}')) u
JOIN node m ON m.nptr=u.dst WHERE m.s LIKE 'masking:%' ORDER BY 1;

\echo
\echo ===== 5. IF STILL AMBIGUOUS, RUN THIS ACTIVE TEST =====
\echo (ranked by how many surviving candidates it separates. Prefer the
\echo  counter reads above: they are passive and cost nothing)
\echo
SELECT replace(t.s,'test: ','') AS test,
  count(DISTINCT c.nptr) AS separates,
  string_agg(DISTINCT replace(c.fault,'fault: ',''), ' | ') AS between_these,
  (SELECT cm.s FROM unnest(COALESCE(t.ie3,'{}')) tu JOIN node cm ON cm.nptr=tu.dst
    WHERE cm.s LIKE 'command:%' LIMIT 1) AS how
FROM node t, unnest(COALESCE(t.im1,'{}') || COALESCE(t.il1,'{}')) tu2
JOIN candidate c ON c.nptr = tu2.dst
WHERE t.s LIKE 'test:%'
GROUP BY t.nptr, t.s, t.ie3 ORDER BY separates DESC, test;
