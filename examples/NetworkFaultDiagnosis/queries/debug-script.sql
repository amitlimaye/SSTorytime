-- Guided debug script for one hypothesis.
--
--   psql -d sstoryline -v hyp="'ecmp hash polarisation'" -f debug-script.sql
--
-- Emits an ORDERED, BRANCHING script to prove or disprove one fault, with
-- every step carrying a real telemetry path, a window, a decision rule and
-- a citation back to the document the step rests on.
--
-- Nothing here is inferred. Every field is a stored fact, retrieved and
-- ordered. The graph is the memory; the agent executing this script is the
-- reasoner. That division is deliberate -- see the README.
--
-- Ordering is by cost, because the cheapest adequate observation should
-- always come first:
--   step class 0  desk check   -- config and design docs, no device touched
--   step class 1  passive read -- telemetry, no traffic perturbed
--   step class 2  active test  -- injects traffic or changes state
-- and within a class, checks that are decisive in BOTH directions first,
-- since those end the branch either way.

\if :{?hyp} \else \set hyp '''ecmp hash polarisation''' \endif

\set QUIET on
CREATE TEMP VIEW target AS
  SELECT nptr, s FROM node
  WHERE s LIKE 'fault:%' AND s ILIKE '%' || :hyp || '%' LIMIT 1;
\set QUIET off

\echo
\echo ############################################################
\echo '# GUIDED DEBUG SCRIPT'
\echo ############################################################
SELECT s AS hypothesis_under_test FROM target;

\echo
\echo '--- What this fault is, and what it would explain ---'
SELECT n.s AS statement
FROM target t, node f, unnest(COALESCE(f.ie3,'{}')) u JOIN node n ON n.nptr = u.dst
WHERE f.nptr = t.nptr AND (n.s NOT LIKE 'precondition:%' AND n.s NOT LIKE 'test:%'
  AND n.s NOT LIKE 'check:%' AND n.s NOT LIKE 'prior:%')
ORDER BY 1;

\echo
\echo '=== STEP CLASS 0 : DESK CHECKS (no device touched) ==='
\echo '(if a precondition does not hold, stop here -- this fault is not'
\echo ' possible in this fabric as currently configured)'
\echo
SELECT pre.s AS precondition,
       COALESCE((SELECT st.s FROM unnest(COALESCE(pre.ie3,'{}')) su
                   JOIN node st ON st.nptr = su.dst
                  WHERE st.s LIKE 'status:%' LIMIT 1),
                'status: UNEVALUATED -- check the config') AS verdict
FROM target t, node f, unnest(COALESCE(f.ie3,'{}')) u
JOIN node pre ON pre.nptr = u.dst
WHERE f.nptr = t.nptr AND pre.s LIKE 'precondition:%'
ORDER BY 1;

\echo
\echo '=== STEP CLASS 1 : PASSIVE TELEMETRY (guided by counter schema) ==='
\echo
WITH chk AS (
  SELECT n.nptr, n.s, a.short AS effect
  FROM target t, node n, unnest(COALESCE(n.im1,'{}') || COALESCE(n.il1,'{}')) l
  JOIN arrowdirectory a ON a.arrptr = l.arr
  WHERE n.s LIKE 'check:%' AND l.dst = t.nptr
    AND a.short IN ('confirms','excludes')
)
SELECT
  row_number() OVER (ORDER BY
      CASE WHEN strength LIKE '%decisive in both%' THEN 0
           WHEN strength LIKE '%decisive%' THEN 1 ELSE 2 END, chk.s) AS step,
  replace(chk.s,'check: ','')                      AS observation,
  CASE WHEN chk.effect='excludes' THEN 'a TRUE reading RULES THIS OUT'
       ELSE 'a TRUE reading supports it' END       AS meaning,
  path                                             AS read_path,
  kind                                             AS how_to_read,
  scope                                            AS at_scope,
  win                                              AS over_window,
  if_t                                             AS if_true,
  if_f                                             AS if_false,
  strength                                         AS caveat
FROM chk,
LATERAL (
  SELECT
    (SELECT c2.s FROM unnest(COALESCE(cn.ie3,'{}')) cu JOIN node c2 ON c2.nptr=cu.dst
      WHERE c2.s LIKE 'counter:%' LIMIT 1) AS ctr,
    (SELECT w.s FROM unnest(COALESCE(cn.ie3,'{}')) wu JOIN node w ON w.nptr=wu.dst
      WHERE w.s LIKE 'window:%' LIMIT 1) AS win,
    -- distinguish the two outcomes by ARROW, not by node text: both
    -- results are 'result:' nodes and only the arrow says which is which
    (SELECT r.s FROM unnest(COALESCE(cn.ie3,'{}')) ru
       JOIN node r ON r.nptr=ru.dst
       JOIN arrowdirectory ar ON ar.arrptr = ru.arr
      WHERE ar.short = 'if-true' LIMIT 1) AS if_t,
    (SELECT r.s FROM unnest(COALESCE(cn.ie3,'{}')) ru
       JOIN node r ON r.nptr=ru.dst
       JOIN arrowdirectory ar ON ar.arrptr = ru.arr
      WHERE ar.short = 'if-false' LIMIT 1) AS if_f,
    (SELECT st.s FROM unnest(COALESCE(cn.ie3,'{}')) su JOIN node st ON st.nptr=su.dst
      WHERE st.s LIKE 'strength:%' LIMIT 1) AS strength
  FROM node cn WHERE cn.nptr = chk.nptr
) props,
LATERAL (
  -- bind the semantic counter to the platform schema entry, which is what
  -- makes this executable rather than advisory
  SELECT
    (SELECT p.s FROM unnest(COALESCE(cnode.ie3,'{}')) pu JOIN node p ON p.nptr=pu.dst
      WHERE p.s LIKE 'path:%' LIMIT 1) AS path,
    (SELECT k.s FROM unnest(COALESCE(cnode.ie3,'{}')) ku JOIN node k ON k.nptr=ku.dst
      WHERE k.s LIKE 'kind:%' LIMIT 1) AS kind,
    (SELECT sc.s FROM unnest(COALESCE(cnode.ie3,'{}')) su JOIN node sc ON sc.nptr=su.dst
      WHERE sc.s LIKE 'scope:%' LIMIT 1) AS scope
  FROM node cnode WHERE cnode.s = props.ctr
) sch
ORDER BY step;

\echo
\echo '=== STEP CLASS 2 : ACTIVE TESTS (only if still ambiguous) ==='
\echo
SELECT replace(t2.s,'test: ','') AS test,
       (SELECT cm.s FROM unnest(COALESCE(t2.ie3,'{}')) cu JOIN node cm ON cm.nptr=cu.dst
         WHERE cm.s LIKE 'command:%' LIMIT 1) AS how,
       (SELECT r.s FROM unnest(COALESCE(t2.ie3,'{}')) ru JOIN node r ON r.nptr=ru.dst
         WHERE r.s LIKE 'result:%' LIMIT 1) AS if_true
FROM target tg, node t2, unnest(COALESCE(t2.im1,'{}') || COALESCE(t2.il1,'{}')) l
WHERE t2.s LIKE 'test:%' AND l.dst = tg.nptr
ORDER BY 1;

\echo
\echo '=== IF EVERY CHECK COMES BACK NEGATIVE ==='
\echo '(do not discard the hypothesis before reading these)'
\echo
SELECT m.s AS masking_to_rule_out
FROM target t, node f, unnest(COALESCE(f.il1,'{}')) u JOIN node m ON m.nptr = u.dst
WHERE f.nptr = t.nptr AND m.s LIKE 'masking:%';

\echo
\echo '=== PROVENANCE : what this script rests on ==='
\echo
SELECT d.s AS document
FROM target t, node f, unnest(COALESCE(f.ie3,'{}')) u JOIN node d ON d.nptr = u.dst
WHERE f.nptr = t.nptr AND d.s LIKE 'source:%';
