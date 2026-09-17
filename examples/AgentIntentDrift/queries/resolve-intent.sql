-- Resolve a runtime intent string into a dense admissible set.
--
--   psql -d sstoryline -v intent="'fix D-Bus issue'" -f resolve-intent.sql
--
-- The intent arrives at runtime and is three or four words. The density
-- comes from the provision-time keyword lexicon: tokenise, match each
-- keyword against concept names, spellings, aliases and identifiers, then
-- take the union of their expansions.
--
-- Lookup and set union. No model, no inference, nothing generated per run.

\if :{?intent} \else \set intent '''fix D-Bus issue''' \endif

\set QUIET on
-- Every surface form that can name a concept: its own name, its NEAR
-- aliases and spellings, and its declared identifiers.
CREATE TEMP VIEW surface AS
  SELECT c.nptr, c.s AS concept,
         lower(replace(c.s,'concept: ','')) AS form
  FROM node c WHERE c.s LIKE 'concept:%'
  UNION
  SELECT c.nptr, c.s, lower(a.s)
  FROM node c, unnest(COALESCE(c.in0,'{}')) u JOIN node a ON a.nptr = u.dst
  WHERE c.s LIKE 'concept:%' AND a.s NOT LIKE 'concept:%'
  UNION
  SELECT c.nptr, c.s, lower(replace(i.s,'ident: ',''))
  FROM node c, unnest(COALESCE(c.ie3,'{}')) u JOIN node i ON i.nptr = u.dst
  WHERE c.s LIKE 'concept:%' AND i.s LIKE 'ident:%';

CREATE TEMP VIEW token AS
  SELECT DISTINCT lower(t) AS tok
  FROM regexp_split_to_table(:intent, '[^A-Za-z0-9_.-]+') AS t
  WHERE length(t) > 2
    AND lower(t) NOT IN ('the','and','for','with','that','this','all','any','its');

CREATE TEMP VIEW matched AS
  SELECT DISTINCT s.nptr, s.concept, t.tok, s.form
  FROM surface s JOIN token t
    ON s.form = t.tok OR s.form LIKE '%' || t.tok || '%';
\set QUIET off

\echo
\echo '===== KEYWORDS IN =====' 
SELECT string_agg(tok, ', ' ORDER BY tok) AS tokenised, count(*) AS n FROM token;

\echo
\echo '===== CONCEPTS MATCHED =====' 
SELECT DISTINCT tok AS keyword, concept, form AS matched_on FROM matched ORDER BY tok, concept;

\echo
\echo '===== ADMISSIBLE SET (union of expansions) =====' 
SELECT CASE
         WHEN e.s LIKE 'path:%'        THEN '1 path'
         WHEN e.s LIKE 'tool:%'        THEN '2 tool'
         WHEN e.s LIKE 'operation:%'   THEN '3 operation'
         WHEN e.s LIKE 'application:%' THEN '4 application'
         WHEN e.s LIKE 'ident:%'       THEN '5 identifier'
       END AS kind,
       e.s AS member,
       string_agg(DISTINCT replace(m.concept,'concept: ',''), ', ') AS from_concept
FROM matched m JOIN node c ON c.nptr = m.nptr,
     unnest(COALESCE(c.ie3,'{}')) u JOIN node e ON e.nptr = u.dst
WHERE e.s LIKE 'path:%' OR e.s LIKE 'tool:%' OR e.s LIKE 'operation:%'
   OR e.s LIKE 'application:%' OR e.s LIKE 'ident:%'
GROUP BY kind, e.s
ORDER BY kind, member;

\echo
\echo '===== EXCLUSIONS (what these verbs do NOT authorise) =====' 
SELECT DISTINCT x.s AS exclusion, replace(m.concept,'concept: ','') AS for_verb
-- (kw-verb-of) is the reverse reading, so the link sits in the inverse
-- property array on the exclusion node. Scan both directions.
FROM matched m, node x, unnest(COALESCE(x.ie3,'{}') || COALESCE(x.im3,'{}')) u
WHERE x.s LIKE 'exclusion:%' AND u.dst = m.nptr
ORDER BY for_verb, exclusion;

\echo
\echo '===== ONE HOP OUT (related concepts, widen the radius if needed) =====' 
SELECT DISTINCT r.s AS related_concept, replace(m.concept,'concept: ','') AS from_concept
FROM matched m JOIN node c ON c.nptr = m.nptr,
     unnest(COALESCE(c.in0,'{}')) u JOIN node r ON r.nptr = u.dst
WHERE r.s LIKE 'concept:%'
ORDER BY from_concept, related_concept;

\echo
\echo '===== DENSIFICATION =====' 
SELECT (SELECT count(*) FROM token) AS keywords_in,
       (SELECT count(DISTINCT nptr) FROM matched) AS concepts_matched,
       (SELECT count(*) FROM (
          SELECT DISTINCT e.s FROM matched m JOIN node c ON c.nptr=m.nptr,
          unnest(COALESCE(c.ie3,'{}')) u JOIN node e ON e.nptr=u.dst
          WHERE e.s LIKE 'path:%' OR e.s LIKE 'tool:%' OR e.s LIKE 'operation:%'
             OR e.s LIKE 'application:%' OR e.s LIKE 'ident:%') z) AS admissible_members,
       -- widening the radius by one hop pulls in the neighbouring concepts'
       -- expansions too. For this task that is the difference between
       -- knowing about dbus config and knowing where the fix actually goes.
       (SELECT count(*) FROM (
          SELECT DISTINCT e.s
          FROM matched m JOIN node c ON c.nptr=m.nptr,
               unnest(COALESCE(c.in0,'{}')) hu JOIN node h ON h.nptr=hu.dst,
               unnest(COALESCE(h.ie3,'{}')) u JOIN node e ON e.nptr=u.dst
          WHERE h.s LIKE 'concept:%'
            AND (e.s LIKE 'path:%' OR e.s LIKE 'tool:%' OR e.s LIKE 'operation:%'
             OR e.s LIKE 'application:%' OR e.s LIKE 'ident:%')) z2) AS plus_one_hop;
