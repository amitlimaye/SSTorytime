-- Ingestion lint: run this after loading a batch of incident reports.
--
-- Feeding many reports into one graph fails in a predictable way: each report
-- invents its own near-synonym of a mode or an indicator, the vocabulary
-- forks, and the detector stops matching anything. These checks catch that
-- while it is still cheap to fix.
--
--   psql -d sstoryline -f lint-ingestion.sql

\echo
\echo === 1. Classification nodes defined outside the reference model ===
\echo (an incident invented its own mode or indicator instead of linking to one)
\echo

SELECT s AS node, chap AS defined_in
FROM node
WHERE (s LIKE 'mode:%' OR s LIKE 'indicator:%')
  AND chap NOT LIKE '%reference model%'
ORDER BY s;

\echo
\echo === 2. Incidents with no drift mode assigned ===
\echo (unclassified, so invisible to every detector query)
\echo

SELECT i.s AS incident
FROM node i
WHERE i.s LIKE 'incident:%'
  AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(i.ie3,'{}')) u
      JOIN node m ON m.nptr = u.dst
      WHERE m.s LIKE 'mode:%'
  )
ORDER BY i.s;

\echo
\echo === 3. Indicators with no machine observable signal ===
\echo (nothing a detector can compute, so they can only be applied by hand)
\echo

SELECT ind.s AS indicator
FROM node ind
WHERE ind.s LIKE 'indicator:%'
  AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(ind.ie3,'{}')) u
      JOIN node sg ON sg.nptr = u.dst
      WHERE sg.s LIKE 'signal:%'
  )
ORDER BY ind.s;

\echo
\echo === 4. Indicators with no benign explanation recorded ===
\echo (these are the ones that will generate the false positives that get the
\echo  detector switched off, so every indicator needs its benign twin)
\echo

-- The benign twin hangs off the indicator rather than off each signal,
-- because one indicator usually has several signals and one innocent
-- explanation that covers all of them.
SELECT ind.s AS indicator
FROM node ind
WHERE ind.s LIKE 'indicator:%'
  AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(ind.ie3,'{}')) u
      JOIN node b ON b.nptr = u.dst
      WHERE b.s LIKE 'benign:%'
  )
ORDER BY ind.s;

\echo
\echo === 5. Modes with no guardrail ===
\echo (detectable but not actionable: the detector can only report, not advise)
\echo

SELECT m.s AS mode
FROM node m
WHERE m.s LIKE 'mode:%'
  AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(m.ie3,'{}')) u
      JOIN node g ON g.nptr = u.dst
      WHERE g.s LIKE 'guardrail:%'
  )
ORDER BY m.s;
