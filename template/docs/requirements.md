# Requirements

<!-- The product's requirements document: what must be true, stated so it can be tested.
     Built and roasted by /teamwright:requirements; the spec tool and the tasks are derived from it.
     Write only what the owner said or approved. A guess is marked "working assumption" in section 10;
     an unknown goes to docs/open-questions.md. IDs (FR-NN, NFR-NN) are never reused. -->

Version: 0 · Status: draft · Approved by the owner: — · Roast: — (`docs/requirements.reviews/`)
Source: <the owner's documents this was built from, or "interview">

## 1. Problem and users

<!-- Jobs To Be Done: "When <situation>, I want <motivation>, so I can <outcome>." Who the users are and
     what they do today without the product. -->

## 2. First release: goal and success

<!-- The one flow that must work end to end, and how we will know the release succeeded
     (a number and a date, not "users like it"). -->

## 3. Scope

<!-- User story map: user activities left to right; under each, the steps. The release-1 slice is the thinnest
     path through every activity. Priorities MoSCoW. "Won't" is as important as "Must". -->

| Activity | Steps | Release 1 | Priority |
|---|---|---|---|
| <activity> | <steps> | yes / no | Must / Should / Could / Won't |

**Not doing (no-gos):** <what is explicitly out, and why>

## 4. Functional requirements

<!-- EARS: "When <trigger>, the system shall <response>." Unwanted behaviour:
     "If <condition>, then the system shall <response>." — that line is the failure branch.
     Acceptance via Example Mapping: a rule, concrete examples, at least one failing example. -->

| ID | Requirement (EARS) | Acceptance: examples, including a failing one | Priority | Release |
|---|---|---|---|---|
| FR-01 | <When ..., the system shall ...> | <Given ... When ... Then ...; failure: ...> | Must | 1 |

## 5. Non-functional requirements

<!-- ISO/IEC 25010 as a checklist — only the characteristics that apply, each with a number:
     performance, security, privacy, reliability, compatibility, usability, maintainability, portability. -->

| ID | Characteristic | Requirement (measurable) | How it is checked | Priority | Release |
|---|---|---|---|---|---|
| NFR-01 | <security> | <secrets never appear in logs> | <scanner in CI; log allowlist test> | Must | 1 |

## 6. Constraints

<!-- Platforms and versions, store policies, law (personal data, payments), deadline, budget, team. -->

## 7. Glossary and data

<!-- Ubiquitous language: the domain terms as the owner uses them; the main entities and their key fields. -->

| Term | Meaning |
|---|---|
| <term> | <meaning> |

## 8. Integrations and external dependencies

<!-- External APIs, auth, payments, notifications; which are paid, rate-limited or need an account. -->

## 9. Technical decisions

<!-- Derived from the requirements during the roast, approved by the owner. Each with the requirements
     that drive it and the alternative considered. -->

| Decision | Choice | Driven by | Alternative |
|---|---|---|---|
| Stack and areas | <...> | <FR / NFR / constraint ids> | <...> |
| What "deployed" means | <e.g. API on staging; app build installed on an emulator> | <...> | <...> |
| Where verification runs | <local / staging / production-like> | <...> | <...> |
| UI verification | <runner from providers/ui_verify, or none: no UI / deferred because ...> | <...> | <...> |

## 10. Assumptions, risks, open questions

<!-- Every assumption with a status. Pre-mortem: "three months after release 1, it failed — why?"
     Open questions live in docs/open-questions.md; list their ids here. -->

| Assumption or risk | Status | What it affects |
|---|---|---|
| <...> | confirmed / working assumption / open | <ids> |
