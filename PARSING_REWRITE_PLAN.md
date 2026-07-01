# Tula Expense Parsing — Rewrite Plan & Layered Review

Status: proposal for review. No implementation yet.
Goal: precise, consistent voice-log and quick-log that works for everyone, with the LLM demoted from "the brain" to an optional assistant.

---

## 1. Where it fails today (root-cause analysis, from the code)

The current pipeline is **LLM-as-spine with rule fallbacks**, glued together across three divergent call sites. That design is the source of every symptom you reported.

| Symptom you saw | Root cause in code |
|---|---|
| **Merchant wrong** ("Sbii Spend One 40") | No real entity recognition. The rule parser takes "leftover tokens after stripping amount/account/category" as the merchant (`parseSingle` step 5). The LLM, meanwhile, hallucinates. Neither *recognises* a merchant — they guess from residue. |
| **No items** | The data model has a single `note: String?` — there is **no line-item concept**. "apples, tomatoes, onions, ginger garlic paste" has nowhere to live, so it's dropped or jammed into one string. |
| **Amount wrong** (140→40) | Amount was taken from the LLM, which drops digits. (Partially fixed: we now prefer the rule parser's regex amount.) The deeper issue: multi-amount sentences were never segmented in the overlay. |
| **Card/category wrong** | Category was resolved *model-first*. (Partially fixed with the deterministic `CategoryClassifier`.) |
| **Inconsistent behaviour** | Three separate resolution chains: `VoiceInputOverlay.buildResultData`, `HomeView.handleVoiceQuickLog`, `HomeView.handleVoiceMultiQuickLog`. They drifted apart. A fix in one doesn't fix the others. **DRY violation = correctness violation.** |
| **"Depends which provider"** | Default is Gemini; Apple FM is hidden; `bestProvider` silently changes the engine based on device + config. Same input → different output on different phones. |

**The core architectural mistake:** we ask a probabilistic text generator to do *deterministic* work (pull the digits, match the account name) that a parser does perfectly, and we ask the parser to do *fuzzy* work (recognise a novel merchant name) that it can't. The responsibilities are inverted.

---

## 2. How the industry does it (research)

The consistent pattern across finance NLP, receipt-OCR systems, and on-device NLP is **a hybrid pipeline that routes each field to the technique that's actually good at it** — not one model doing everything.

- **NER for structured entities.** Named-entity recognition is the standard way to pull monetary values, organization names, and quantities out of free text; expense systems then do an *item-by-item* classification of the extracted entities. ([IBM — What is NER](https://www.ibm.com/think/topics/named-entity-recognition), [USPTO 10,235,720 — merchant identification & expense item classification](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10235720))
- **Apple ships on-device NER for free.** `NaturalLanguage`'s `NLTagger` with the `.nameType` scheme returns `OrganizationName` and `PlaceName` tags — i.e. *merchant* — entirely on-device, private, offline, on every iOS device. ([Apple — Identifying people, places, organizations](https://developer.apple.com/documentation/naturallanguage/identifying-people-places-and-organizations), [Apple — NLTagger](https://developer.apple.com/documentation/NaturalLanguage/NLTagger))
- **Keyword→category mapping is a first-class step**, not an afterthought — narrowing to purchase/merchant categories via curated maps is exactly what our `CategoryClassifier` now does. ([ChatFin — NLP in finance](https://chatfin.ai/blog/nlp-in-finance-natural-language-processing-for-financial-analysis-guide/))
- **LLMs are used for the hard, fuzzy residue** (zero-shot extraction when rules/NER are uncertain), with prompting guardrails — as an *assist*, not the foundation. ([John Snow Labs — NLP in financial services](https://www.johnsnowlabs.com/examining-the-impact-of-nlp-in-financial-services/))

**Verdict on "is the LLM necessary?":** No. For short expense utterances, a deterministic + on-device-NER stack is more accurate, faster, free, private, and identical on every device. The LLM should be an optional last-mile assist for genuinely ambiguous inputs — and the app must work perfectly with it switched off.

---

## 3. Proposed architecture — one pipeline, field-by-field ownership

A single `ExpenseInterpreter` (used by **both** voice and quick-log; voice merely adds transcription in front). One source of truth, replacing the three divergent chains.

```
raw text
  → Segmenter            (split multi-expense: "140 SBI and 40 cash" → 2)
  → for each segment:
      Amount   extractor  [deterministic: regex + number-words]      ← never the LLM
      Date     extractor  [deterministic: relative-date parser]      ← never the LLM
      Account  extractor  [deterministic: match user's accounts]     ← never the LLM
      Merchant extractor  [NLTagger NER → "at/from X" → user history] ← on-device, free
      Items    extractor  [item span → split on comma/and → lexicon]  ← deterministic
      Category resolver   [CategoryClassifier → merchant history]     ← deterministic
      Confidence scorer   [per field]
  → (optional) LLM assist ONLY for fields still low-confidence
  → [ExpenseDraft]  → confidence-flagged review UI (already built)
```

Ownership rule (the heart of it):

| Field | Primary (deterministic / on-device) | LLM allowed to…|
|---|---|---|
| Amount | regex + number-words | never override a found amount |
| Date | relative-date parser | never override |
| Account | exact match vs user's accounts | only suggest if none matched |
| Merchant | **NLTagger NER** + preposition + history | suggest only if NER + history both empty |
| Items | span split + lexicon | enrich names only |
| Category | `CategoryClassifier` + merchant→category history | suggest only if classifier silent |

**Data-model change required for "items":** add line items to `Expense` (either `var items: [LineItem]` via a SwiftData relationship, or a structured `note`). This is what makes "apples, tomatoes, onions, ginger garlic paste" representable at all.

---

## 4. Layered review (developer → manager → senior manager)

I ran the plan through three review passes, as you asked. Each caught real problems and changed the plan.

### Pass 1 — Developer review (correctness, edge cases)
- **Finding:** `NLTagger` is trained on general English; it will miss Indian merchants like "Sunday Santha" and may tag dishes as orgs. → **Change:** Merchant = *ensemble of three cheap signals* (NER + "at/from" preposition span + user merchant history/fuzzy rules), not NER alone. Highest-agreement wins; LLM only if all three are empty.
- **Finding:** Splitting items on "and" is dangerous — "ginger garlic paste" is one item, "idli and dosa" is two. → **Change:** split on commas first; treat "and" as a separator only when both sides independently hit the item lexicon.
- **Finding:** Segmenter must not split "bills and utilities" (a category) into two expenses. → **Change:** only segment when ≥2 amounts are present (rule already exists; formalise it).

### Pass 2 — Manager review (scope, does it actually fix the tickets, testability)
- **Finding:** "Rewrite from scratch" is high-risk on a shipping app; the deterministic extractors (amount, date, account, number-words, relative dates) already work and are well-tested. → **Change:** **Refactor-and-consolidate, not greenfield.** Keep the good extractors; the rewrite is really *unifying three code paths into one interpreter + adding NER merchant + items + a measurement harness*. Lower risk, same outcome.
- **Finding:** No way to prove it's better. → **Change:** **Phase 0 is a golden-set test harness** (50+ real utterances incl. your failing ones) measuring per-field accuracy *before* any change. Every phase must move the number up. Evidence before claims.
- **Finding:** Data-model change touches persistence + widgets + share extension. → **Change:** ship items behind the parser first (store as structured `note`), do the SwiftData relationship as a separate migration PR.

### Pass 3 — Senior-manager review (strategy, privacy, cost, longevity)
- **Finding:** "Works for everyone" must mean *works offline, no API key, identical on every device.* → **Mandate:** the deterministic + on-device path is the **default and complete product**. LLM is opt-in enhancement, never required. Privacy story becomes a feature.
- **Finding:** Provider ambiguity is a support/QA liability. → **Mandate:** make the engine explicit and observable; stop silently switching. Decide one default.
- **Finding:** Cost/latency of cloud calls on every entry is unjustified once deterministic accuracy is high. → **Mandate:** gate any LLM call behind a confidence threshold; most entries should never hit it.

Net effect of the reviews: the plan shifted from "rewrite around a better LLM prompt" to **"consolidate into one deterministic-first interpreter, add on-device NER + items, measure everything, LLM optional."**

---

## 5. Proposed phases (for your approval — not started)

- **Phase 0 — Measure.** Golden-set harness (50–80 real inputs, incl. multi-expense, items, multi-account). Baseline per-field accuracy. *Deliverable: a number.*
- **Phase 1 — Consolidate.** Collapse the 3 resolution chains into one `ExpenseInterpreter`. No behaviour change intended; harness proves parity.
- **Phase 2 — Fix the spine.** Harden deterministic amount/account/date; add `NLTagger` merchant ensemble; add multi-item extraction; category via classifier+history.
- **Phase 3 — Items data model.** Structured items in `note` first; SwiftData relationship migration second.
- **Phase 4 — LLM as assist.** Behind a confidence gate; never overrides high-confidence deterministic fields; app fully functional with it off.
- **Phase 5 — Re-measure** vs Phase 0 baseline; iterate on the lexicons/NER ensemble.

---

## 6. Decisions I need from you before implementing

1. **Refactor-and-consolidate vs literal from-scratch rewrite?** (I strongly recommend the former — same result, far less risk, keeps the working extractors.)
2. **LLM role:** optional assist behind a confidence gate (recommended), or remove cloud entirely and go fully on-device?
3. **Items data model:** OK to add a line-items structure to `Expense` (small migration), or keep items as a formatted string in `note` for now?
4. **Provider default:** make Apple FM the default when available + unhide it in Settings, or standardise on one engine?

---

## 7. Locked decisions (your answers)

1. **Approach:** Consolidate + add NER/items. Keep working extractors; unify the 3 paths into one `ExpenseInterpreter`. No greenfield.
2. **LLM:** Optional assist, gated by confidence. Deterministic + on-device NER is the complete default; LLM never overrides a high-confidence deterministic field; app fully works with it off.
3. **Items:** Add a proper SwiftData line-items relationship to `Expense` now (migration done carefully across app + widget + share extension).
4. **Provider:** User-configured AI first, then Apple FM, then deterministic-only. (Details below.)

## 8. Provider resolution (explicit, observable)

```
func resolveEngine() -> Engine {
    if userConfiguredProvider.isReady { return .cloud(userProvider) }   // 1. user's choice (e.g. Gemini w/ key)
    if AppleFM.isAvailable           { return .appleFM }                // 2. on-device, if supported
    return .none                                                        // 3. deterministic-only
}
```

- **No AI configured AND no Apple FM** (e.g. older iPhone, no key): engine = `.none`. The interpreter still runs the full deterministic + `NLTagger` pipeline — **no error, no banner, no degradation**, just no LLM assist. This path must be tested explicitly as a first-class case, not an afterthought.
- The chosen engine is surfaced in the UI (the provider badge already exists) so behaviour is never a silent mystery.
- LLM (cloud or FM) is invoked **only** when `engine != .none` *and* at least one field is below the confidence threshold.

## 9. Number-compound correction ("one 40" → 140, "two 80" → 280)

Indian-English speech + STT produce "one forty / 1 40" for 140, "two eighty / 2 80" for 280, "three fifty" for 350. We already have the math (`normalizeIndianNumbers`, `mergeIndianCompounds`) — the gap is *when* it runs.

Two-stage correction:

- **Live (as you speak), conservative.** Apply number-compound + split-digit normalization to **finalized transcript segments only** (never the volatile live partial — that's what caused flicker before). Only transformations that are unambiguous *and* amount-safe (never shrink a number). So once a phrase finalizes, "one 40" visibly becomes "140" before you ever tap Process.
- **On Process, full.** Run the complete normalization (+ the existing FM `correctTranscript` pass when an engine is available), still behind the amount-safety guard that rejects any correction that would shrink the amount.

Edge guard: a bare "one" / "two" with no tens partner is left alone (it's usually a quantity, not 100/200) — the existing conservative single-word rule already handles this.

## 10. Build order (concrete, for approval to start)

- **P0 — Golden-set harness.** 50–80 real utterances incl. your failing ones (multi-expense, item lists, multi-account, "one 40"). Per-field accuracy baseline. *Runs in Swift tests; I'll also mirror logic in a Python harness I can execute here for fast iteration evidence.*
- **P1 — `ExpenseInterpreter`.** Collapse the 3 chains into one; prove parity on the harness.
- **P2 — Merchant NER ensemble + multi-item extraction + live number correction.**
- **P3 — Line-items SwiftData migration** (Expense ↔ LineItem), wire UI/widget/share.
- **P4 — LLM assist behind confidence gate**, with the `.none` engine path tested.
- **P5 — Re-measure vs P0; iterate lexicons/NER.**
```

---

## 11. Grounded prompt enrichment (the LLM-assist contract) — quick-log, voice, scan

Inspired by how Xcode enriches a terse request before sending it to the model. We adopt the **grounded** variant: never a free-text rewrite round-trip, always a structured envelope built from the deterministic pre-parse + the user's real data. One shared `ContextEnvelope` builder (extends today's `FMContextBuilder`) used by all three surfaces (DRY).

**Contract (identical everywhere):**
1. Deterministic pipeline runs first and resolves everything it can (amount, date, account, items, category) with per-field confidence.
2. We build an envelope: `CONTEXT` (today, the user's accounts, categories, frequent merchants) + `PRE-PARSE` (resolved fields marked high-confidence "do not change") + explicitly `UNRESOLVED` fields.
3. **One** LLM call, only when engine ≠ `.none` **and** ≥1 field is low-confidence. Its job is to fill `UNRESOLVED`/low-confidence fields only.
4. **Post-response reconcile:** high-confidence deterministic fields always win, even if the model returns something different. The model can never overwrite a digit we already read or an account we already matched.

**Per surface:**

- **Quick-log (typed):** live number/homophone canonicalization on the text field → deterministic pre-parse → envelope → optional assist. Fast path: if everything is high-confidence, save with no LLM call at all.
- **Voice:** transcript → live canonicalization (finalized segments) → deterministic pre-parse → envelope → optional assist. Same envelope as quick-log.
- **Scan (receipt/OCR):** OCR text (and, in image mode, the image) → deterministic regex pre-parse (grand-total candidate, date, header merchant, line items) → envelope **with the document-type layout hint** (UPI / order summary / restaurant / hospital / utility, already in `parseReceipt`) → assist fills gaps / disambiguates the grand total. The "amount printed verbatim, never sum" and "same value twice = one bill" guards move into deterministic pre-parse so they hold even with the LLM off.

Net: the model, when used at all, "gets it at first glance" — but it's grounded in facts, costs one call, and can't corrupt what we already know. And because the envelope also sharpens the deterministic path (merchant NER, category), the `.none` engine still benefits from the same enrichment.
```
