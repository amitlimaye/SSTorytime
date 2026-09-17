# lexicon/ — where the density comes from

A runtime intent is three or four words. `"Fix D-Bus issue"` is not a graph
you can measure anything against.

The density comes from here. **Each keyword is a concept, expanded at
provision time into its variations and its applications.** D-Bus is D-Bus
regardless of which run names it, so the expansion is a fact about the
domain vocabulary, not about any task — which is what lets it be built
offline, by an LLM from the docs, and reviewed by a human.

At runtime:

```
"fix D-Bus issue"
   ├─ tokenise                → {fix, dbus, issue}
   ├─ match concepts by name, identifier or alias
   └─ union of expansions     → the admissible set
```

Lookup and set union. No model, no inference, no per-run generation.

## What each concept carries

| arrow | holds |
| --- | --- |
| `kw-ident` | the literal strings that name it — package ids, service names, binaries |
| `alias` / `sp` | spellings and synonyms, so tokenising `D-Bus` and `dbus` both hit |
| `kw-path` | where it lives on disk |
| `kw-tool` | what you inspect it with |
| `kw-op` | what operations legitimately modify it |
| `kw-use` | what it is used for |
| `kw-rel` | neighbouring concepts, for hop expansion |

## Why expanding *keywords* is safe when expanding *intent* is not

Expanding the intent — generating restatements of the goal — widens the
admissible set with a model's guesses about what the user might have meant.
Drift is plausible by construction, so those guesses tend to include the
drift, and the detector authorises it.

Expanding a keyword is different in kind. `kw-path`, `kw-tool` and `kw-op`
are **documented facts about a domain object**: where D-Bus config lives,
what modifies it. They come from man pages, config schemas and package
metadata, and a human can check every line against a source. The expansion
is bounded by what the system actually is, not by what a model imagines the
task could have been.

The practical test when adding an entry: *could I cite a document for this?*
If not, it is intent expansion wearing a lexicon's clothes.

## Verbs

Verb concepts (`fix`, `check`, `investigate`) carry `kw-verb` — the
operation classes that realise them. This is the part to keep tightest,
because a verb expanded loosely authorises everything. `fix` realised by
"edit a config file" is documented practice. `fix` realised by "do whatever
makes the symptom stop" is how you get a deleted database.
