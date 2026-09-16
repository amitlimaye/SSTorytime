-- Probable cause ranking from observed symptoms.
--
--   psql -d sstoryline \
--     -v symptoms="'intermittent loss,average interface utilisation,batch job'" \
--     -f probable-cause.sql
--
-- :symptoms is a comma separated list of substrings matched against symptom
-- node text, so an operator can paste phrases from a ticket.
--
-- READ THIS BEFORE TRUSTING THE ORDER.
--
-- The score is a transparent heuristic, not a posterior probability. It is
--   3 points per observed symptom the fault explains
-- + 1 point per time it has been the confirmed root cause in this fabric
-- + 2 if its precondition holds here, -4 if the config says it cannot
-- Nothing about that is Bayesian and it must never be presented as though
-- it were. The honest reading of a rank is "how much of what you observed
-- would this explain", not "how likely is this".
--
-- The output to act on is the LAST section, not the first. The ranking
-- exists to choose a discriminating test; the test is the product.

\if :{?symptoms} \else \set symptoms '''intermittent loss,average interface utilisation,batch job''' \endif

\set QUIET on
CREATE TEMP VIEW observed AS
  SELECT DISTINCT n.nptr, n.s
  FROM node n, unnest(string_to_array(:symptoms, ',')) AS term
  WHERE n.s LIKE 'symptom:%' AND n.s ILIKE '%' || btrim(term) || '%';

-- Faults that directly explain at least one observed symptom.
CREATE TEMP VIEW direct AS
  SELECT f.nptr, f.s AS fault,
         count(DISTINCT o.nptr) AS explains
  FROM node f
  JOIN observed o ON EXISTS (
      SELECT 1 FROM unnest(COALESCE(f.il1,'{}')) WHERE dst = o.nptr
  )
  WHERE f.s LIKE 'fault:%'
  GROUP BY f.nptr, f.s;

-- Recall over precision. A fault that is confusable with a direct
-- candidate is pulled in even though it explains nothing on its own,
-- because "presents identically at the level you looked first" is exactly
-- the case where the symptom list you were given is the misleading part.
-- Omitting the true cause is a worse failure than a longer list.
CREATE TEMP VIEW candidate AS
  SELECT nptr, fault, explains, 'observed'::text AS origin FROM direct
  UNION
  SELECT n.nptr, n.s, 0, 'via confusability'
  FROM node n
  WHERE n.s LIKE 'fault:%'
    AND n.nptr NOT IN (SELECT nptr FROM direct)
    AND EXISTS (
      SELECT 1 FROM direct d
      JOIN node df ON df.nptr = d.nptr,
           unnest(COALESCE(df.in0,'{}')) u
      WHERE u.dst = n.nptr
    );

-- Properties hanging off a fault, resolved to text.
CREATE TEMP VIEW prop AS
  SELECT f.nptr AS fault_ptr, t.s AS val
  FROM node f, unnest(COALESCE(f.ie3,'{}')) u
  JOIN node t ON t.nptr = u.dst
  WHERE f.s LIKE 'fault:%';
\set QUIET off

\echo
\echo ================= OBSERVED =================
SELECT s AS symptom FROM observed ORDER BY s;

\echo
\echo ================= RANKED CANDIDATES =================
\echo (order is a heuristic over coverage, priors and preconditions -- see header)
\echo

WITH scored AS (
  SELECT c.nptr, c.fault, c.explains, c.origin,
         (SELECT (regexp_match(p.val, '([0-9]+) time'))[1]::int
            FROM prop p WHERE p.fault_ptr = c.nptr AND p.val LIKE 'prior:%'
            AND p.val LIKE '%confirmed root cause%' LIMIT 1) AS priors,
         (SELECT st.s
            FROM node pre, unnest(COALESCE(pre.ie3,'{}')) pu
            JOIN node st ON st.nptr = pu.dst
           WHERE pre.s LIKE 'precondition:%'
             AND st.s LIKE 'status:%'
             AND EXISTS (SELECT 1 FROM prop p2
                          WHERE p2.fault_ptr = c.nptr AND p2.val = pre.s)
           ORDER BY st.s LIMIT 1) AS precond
  FROM candidate c
)
SELECT fault,
       origin,
       explains AS sympt,
       COALESCE(priors,0) AS priors,
       CASE
         WHEN precond LIKE '%does not hold%' THEN 'RULED UNLIKELY by config'
         WHEN precond LIKE '%holds%'         THEN 'possible here'
         ELSE 'unknown'
       END AS precondition,
       explains * 3 + COALESCE(priors,0)
         + CASE WHEN precond LIKE '%does not hold%' THEN -4
                WHEN precond LIKE '%holds%'         THEN  2
                ELSE 0 END AS score
FROM scored
ORDER BY score DESC, fault;

\echo
\echo ================= WHY AN EXPECTED SYMPTOM MAY BE ABSENT =================
\echo (a cause is not ruled out by a missing symptom if something masks it)
\echo

SELECT c.fault, m.s AS masked_by
FROM candidate c
JOIN node f ON f.nptr = c.nptr,
     unnest(COALESCE(f.il1,'{}')) u
JOIN node m ON m.nptr = u.dst
WHERE m.s LIKE 'masking:%'
ORDER BY c.fault;

\echo
\echo ================= RUN THIS NEXT =================
\echo (tests ranked by how many of the surviving candidates they separate --
\echo  this is the output to act on, not the ranking above)
\echo

SELECT t.s AS test,
       count(DISTINCT c.nptr) AS separates,
       string_agg(DISTINCT replace(c.fault,'fault: ',''), ' | ') AS between_these,
       (SELECT cm.s FROM unnest(COALESCE(t.ie3,'{}')) tu
          JOIN node cm ON cm.nptr = tu.dst
         WHERE cm.s LIKE 'command:%' LIMIT 1) AS how
-- (discriminates) is the reverse reading of (discrim-by), so the link is
-- stored in the inverse leadsto array on the test node. Both are scanned
-- so the query does not depend on which direction the note was written in.
FROM node t, unnest(COALESCE(t.im1,'{}') || COALESCE(t.il1,'{}')) tu2
JOIN candidate c ON c.nptr = tu2.dst
WHERE t.s LIKE 'test:%'
GROUP BY t.nptr, t.s, t.ie3
ORDER BY separates DESC, test;
