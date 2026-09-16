#!/usr/bin/env python3
"""
Deterministic diagnosis agent. NO LANGUAGE MODEL.

    ./diagnose.py "my network is slow"
    ./diagnose.py "transfers take forever" --answer "only large transfers"

Reads the pre-processed graph and emits a ranked hypothesis set plus an
executable telemetry plan. Every decision it makes is a lookup or an
arithmetic comparison over stored facts -- there is no model in the loop,
nothing is sampled, and the same input always produces the same output.

The language model was used ONCE, offline, to turn plain-English incident
reports, design docs, functional specs and the ASIC manual into N4L. It is
not present here and is not needed here.

Requires only the standard library and psql on PATH. Connection is taken
from the usual PG* environment variables.
"""

import argparse
import os
import re
import subprocess
import sys

DB = os.environ.get("SST_DB", "sstoryline")

# Deliberately small and fixed. A stopword list is not language understanding,
# it is a lookup table, and it is the entire extent of the text processing
# this agent performs.
STOP = {
    "the", "a", "an", "is", "are", "it", "we", "my", "our", "of", "to",
    "and", "or", "in", "on", "for", "with", "that", "this", "at", "be",
    "i", "am", "get", "got", "very", "really", "all",
}


def sql(query):
    """Run one query, return rows as lists of fields."""
    out = subprocess.run(
        ["psql", "-d", DB, "-tAF", "\x1f", "-c", query],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit("psql failed: " + out.stderr.strip())
    return [line.split("\x1f") for line in out.stdout.splitlines() if line.strip()]


def tokens(text):
    return {w for w in re.findall(r"[a-z]+", text.lower()) if w not in STOP}


# --------------------------------------------------------------------------
# 1. Match the free-text complaint against stored wordings.
#    Lexical overlap, not semantics. If it matches nothing the agent says so
#    rather than guessing -- an unmatched complaint is a wording worth adding
#    to the graph, which is a curation task for a human.
# --------------------------------------------------------------------------

def match_complaint(text):
    rows = sql("""
        SELECT c.s, w.s FROM node c, unnest(COALESCE(c.ie3,'{}')) u
        JOIN node w ON w.nptr = u.dst
        WHERE c.s LIKE 'complaint:%' AND w.s LIKE 'wording:%'
    """)
    want = tokens(text)
    best = {}
    for complaint, wording in rows:
        have = tokens(wording)
        if not have:
            continue
        score = len(want & have) / len(want | have)
        if score > best.get(complaint, (0, ""))[0]:
            best[complaint] = (score, wording)
    ranked = sorted(best.items(), key=lambda kv: -kv[1][0])
    return [(c, s, w) for c, (s, w) in ranked if s > 0]


def questions_for(complaint):
    return [r[0] for r in sql(f"""
        SELECT q.s FROM node c, unnest(COALESCE(c.il1,'{{}}')) u
        JOIN node q ON q.nptr = u.dst
        WHERE c.s = '{complaint}' AND q.s LIKE 'question:%' ORDER BY q.s
    """)]


def answers_for(question):
    return [r[0] for r in sql(f"""
        SELECT a.s FROM node q, unnest(COALESCE(q.ie3,'{{}}')) u
        JOIN node a ON a.nptr = u.dst
        WHERE q.s = '{question}' AND a.s LIKE 'answer:%' ORDER BY a.s
    """)]


def symptoms_for(answer):
    return [r[0] for r in sql(f"""
        SELECT s.s FROM node a, unnest(COALESCE(a.il1,'{{}}')) u
        JOIN node s ON s.nptr = u.dst
        WHERE a.s = '{answer}' AND s.s LIKE 'symptom:%'
    """)]


# --------------------------------------------------------------------------
# 2. Candidates and scoring.
#
#    The scoring rule is four integers and is printed with every answer, so
#    an operator can see exactly why something ranked where it did. That
#    auditability is the point of having no model here.
# --------------------------------------------------------------------------

W_EXPLAINS = 3       # per symptom the fault accounts for
W_UNCOVERED = 3      # no playbook covers it, and the complaint got through
W_SILENT = -3        # a playbook covers it and did not fire
W_PRECOND_OK = 2
W_PRECOND_NO = -4


def candidates(symptoms):
    if not symptoms:
        return []
    inlist = ",".join("'" + s.replace("'", "''") + "'" for s in symptoms)
    rows = sql(f"""
        WITH sym AS (SELECT nptr, s FROM node WHERE s IN ({inlist})),
        direct AS (
          SELECT f.nptr, f.s AS fault, count(DISTINCT sym.nptr) AS explains
          FROM node f JOIN sym ON EXISTS (
            SELECT 1 FROM unnest(COALESCE(f.il1,'{{}}')) WHERE dst = sym.nptr)
          WHERE f.s LIKE 'fault:%' GROUP BY f.nptr, f.s)
        SELECT d.fault, d.explains,
          COALESCE((SELECT (regexp_match(p.s,'([0-9]+) time'))[1]
             FROM node f2, unnest(COALESCE(f2.ie3,'{{}}')) pu JOIN node p ON p.nptr=pu.dst
             WHERE f2.nptr=d.nptr AND p.s LIKE 'prior:%'
               AND p.s LIKE '%confirmed root cause%' LIMIT 1),'0'),
          COALESCE((SELECT st.s FROM node f3, unnest(COALESCE(f3.ie3,'{{}}')) pu
             JOIN node pre ON pre.nptr=pu.dst, unnest(COALESCE(pre.ie3,'{{}}')) su
             JOIN node st ON st.nptr=su.dst
             WHERE f3.nptr=d.nptr AND pre.s LIKE 'precondition:%'
               AND st.s LIKE 'status:%' ORDER BY st.s LIMIT 1),''),
          COALESCE((SELECT pb.s FROM node pb, unnest(COALESCE(pb.im1,'{{}}')
                      || COALESCE(pb.il1,'{{}}')) lu
             WHERE pb.s LIKE 'playbook:%' AND lu.dst = d.nptr LIMIT 1),'')
        FROM direct d
    """)
    out = []
    for fault, explains, priors, precond, playbook in rows:
        explains, priors = int(explains), int(priors)
        score = explains * W_EXPLAINS + priors
        why = [f"explains {explains} symptom(s) = +{explains * W_EXPLAINS}"]
        if priors:
            why.append(f"confirmed {priors}x before = +{priors}")
        # The inversion: a playbook exists because the problem was already
        # solved, so silence from one is evidence against, and absence of
        # any playbook is evidence for.
        if playbook:
            score += W_SILENT
            why.append(f"covered by {playbook} which did not fire = {W_SILENT}")
        else:
            score += W_UNCOVERED
            why.append(f"NO playbook covers this = +{W_UNCOVERED}")
        if "does not hold" in precond:
            score += W_PRECOND_NO
            why.append(f"config says impossible here = {W_PRECOND_NO}")
        elif "holds" in precond:
            score += W_PRECOND_OK
            why.append(f"precondition holds = +{W_PRECOND_OK}")
        out.append((score, fault, playbook, why))
    return sorted(out, reverse=True)


# --------------------------------------------------------------------------
# 3. The executable telemetry plan.
#
#    A check with no machine-evaluable predicate is reported NOT EVALUABLE
#    rather than skipped, because silently skipping it turns an unsettled
#    hypothesis into an apparently excluded one.
# --------------------------------------------------------------------------

def plan_for(fault):
    return sql(f"""
        SELECT chk.s, a.short,
          COALESCE((SELECT p.s FROM node c2, unnest(COALESCE(c2.ie3,'{{}}')) cu
             JOIN node ctr ON ctr.nptr=cu.dst, unnest(COALESCE(ctr.ie3,'{{}}')) pu
             JOIN node p ON p.nptr=pu.dst
             WHERE c2.nptr=chk.nptr AND ctr.s LIKE 'counter:%'
               AND p.s LIKE 'path:%' LIMIT 1),'NO PATH IN SCHEMA'),
          COALESCE((SELECT w.s FROM unnest(COALESCE(chk.ie3,'{{}}')) wu
             JOIN node w ON w.nptr=wu.dst WHERE w.s LIKE 'winsec:%' LIMIT 1),''),
          COALESCE((SELECT g.s FROM unnest(COALESCE(chk.ie3,'{{}}')) gu
             JOIN node g ON g.nptr=gu.dst WHERE g.s LIKE 'aggregate:%' LIMIT 1),''),
          COALESCE((SELECT cp.s FROM unnest(COALESCE(chk.ie3,'{{}}')) cu2
             JOIN node cp ON cp.nptr=cu2.dst WHERE cp.s LIKE 'compare:%' LIMIT 1),''),
          COALESCE((SELECT tg.s FROM unnest(COALESCE(chk.ie3,'{{}}')) tu
             JOIN node tg ON tg.nptr=tu.dst WHERE tg.s LIKE 'trigger:%' LIMIT 1),'')
        FROM node f, node chk, unnest(COALESCE(chk.im1,'{{}}') || COALESCE(chk.il1,'{{}}')) l
        JOIN arrowdirectory a ON a.arrptr = l.arr
        WHERE f.s = '{fault}' AND chk.s LIKE 'check:%' AND l.dst = f.nptr
          AND a.short IN ('confirms','excludes')
        ORDER BY chk.s
    """)


def tests_for(fault):
    """Active tests, the fallback when no counter can settle a hypothesis."""
    return sql(f"""
        SELECT t.s,
          COALESCE((SELECT cm.s FROM unnest(COALESCE(t.ie3,'{{}}')) cu
             JOIN node cm ON cm.nptr=cu.dst
             WHERE cm.s LIKE 'command:%' LIMIT 1),'')
        FROM node f, node t, unnest(COALESCE(t.im1,'{{}}') || COALESCE(t.il1,'{{}}')) l
        WHERE f.s = '{fault}' AND t.s LIKE 'test:%' AND l.dst = f.nptr
        ORDER BY t.s
    """)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("complaint")
    ap.add_argument("--answer", action="append", default=[],
                    help="substring of a stored answer; repeatable")
    ap.add_argument("--top", type=int, default=3)
    args = ap.parse_args()

    print("=" * 74)
    print("DETERMINISTIC DIAGNOSIS -- no language model in this process")
    print("=" * 74)

    matches = match_complaint(args.complaint)
    if not matches:
        sys.exit("\nNo stored complaint wording matches that text.\n"
                 "That is a curation gap, not a diagnosis. Add the wording "
                 "to complaint-model.n4l.")
    complaint, score, wording = matches[0]
    print(f"\ncomplaint in : {args.complaint!r}")
    print(f"matched      : {complaint}  (lexical overlap {score:.2f} with {wording!r})")

    qs = questions_for(complaint)
    chosen, symptoms = [], []
    for q in qs:
        for a in answers_for(q):
            if any(sub.lower() in a.lower() for sub in args.answer):
                chosen.append((q, a))
                symptoms += symptoms_for(a)
    symptoms = sorted(set(symptoms))

    unanswered = [q for q in qs if q not in [c[0] for c in chosen]]
    if unanswered:
        print("\n--- ASK THESE, CHEAPEST FIRST ---")
        for q in unanswered:
            print("  " + q.replace("question: ", "? "))
            for a in answers_for(q):
                print("      - " + a.replace("answer: ", ""))

    if not symptoms:
        print("\nNo answers supplied, so no hypotheses yet. Answer one question "
              "with --answer and re-run.")
        return

    print("\n--- NARROWED TO ---")
    for q, a in chosen:
        print(f"  {a}")
    for s in symptoms:
        print(f"    -> {s}")

    ranked = candidates(symptoms)
    print("\n--- RANKED HYPOTHESES ---")
    for score, fault, playbook, why in ranked[:args.top]:
        print(f"\n  [{score:>3}] {fault}")
        for w in why:
            print(f"        {w}")

    print("\n--- TELEMETRY PLAN FOR THE LEADING HYPOTHESIS ---")
    if not ranked:
        return
    lead = ranked[0][1]
    print(f"  hypothesis: {lead}\n")
    checks = plan_for(lead)
    if not checks:
        # A gap in the graph, not an absence of evidence. Saying nothing here
        # would read as "nothing to do", which is how an open hypothesis gets
        # mistaken for a closed one.
        print("  NO COUNTER CHECK EXISTS FOR THIS HYPOTHESIS.")
        print("  This is a gap in the graph, not a clean bill of health.")
        print("  It cannot be confirmed from telemetry. Fall back to:\n")
        for t, how in tests_for(lead) or [("  none recorded either", "")]:
            print(f"  * {t}")
            if how:
                print(f"      {how}")
        print("\n  Then add a counter check for it, so the next operator")
        print("  does not have to run an active test to answer this.")
        return
    for chk, effect, path, winsec, agg, cmp_, trig in checks:
        evaluable = all([winsec, agg, cmp_, trig]) and path != "NO PATH IN SCHEMA"
        print(f"  * {chk}")
        print(f"      effect if true : {'EXCLUDES' if effect == 'excludes' else 'confirms'}")
        print(f"      path           : {path}")
        if evaluable:
            print(f"      {winsec}")
            print(f"      {agg}")
            print(f"      {cmp_}")
            print(f"      {trig}")
        else:
            print("      NOT EVALUABLE -- no machine predicate stored.")
            print("      Hypothesis stays OPEN. Do not report it as excluded.")
        print()


if __name__ == "__main__":
    main()
