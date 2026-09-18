# Packaging, in source form

Two machine-readable files and one rule.

| File | What it holds |
|---|---|
| [`app-manifest.json`](app-manifest.json) | Every record the scoped application is made of — Script Includes, the hook, the two tables, the ten properties, the roles, the credential/connection/alias/REST-Message set, the ACL set, the fixtures. |
| [`release.json`](release.json) | What this release candidate is pinned to: the Store app version, the authoritative contract references, and the target ServiceNow release — which is **NOT PINNED**, with the reason written out. |

**The rule: this directory contains no installable artefact, and that is the
point.**

---

## Why there is no update set here

An update-set XML that names one field wrong imports silently wrong. Nothing in
this repository has executed on a ServiceNow instance, so a hand-written XML
would be a guess dressed up as an artefact — and the one artefact type whose
failure mode is *silent* is the worst possible place to put a guess.

The path is the other way round: the sources and record specifications are
complete and locally tested, **you build the application once on an instance**
from them, and you **export** the update set from there
(`../README.md` § Export the update set). That exported set is the artefact that
travels to other instances, and it is committed with the instance family and
patch level in the commit message.

Nothing in this repository may be described as install-verified, and
`release.json` carries `instance_validation: "pending"` until a gate record says
otherwise.

## What the manifest is actually load-bearing for

`../test/packaging.test.js` checks four agreements that used to be maintained by
hand across four places:

1. Every file in `src/script_includes/` is listed, and every listed source
   exists. Adding a Script Include without listing it fails.
2. The property set agrees **three ways**: the manifest, `LucairnConfig.PROP`,
   and the table in `src/records/properties.md`. A property documented but never
   read, or read but never documented, fails.
3. The table names agree with `LucairnConfig.TABLE_SKILL_POLICY` and
   `LucairnEvidence.TABLE`.
4. Every scoped name carries the `x_lcrn_now_assist` placeholder, and every
   scope-substitution site named in the manifest exists on disk.

That is the whole claim. It is an inventory-consistency check, not a validation
of anything ServiceNow does.

## The target release — three facts, kept apart

A release candidate has to be built *for* something. `release.json` therefore
pins an intended target, and keeps it strictly separate from two things it is
constantly mistaken for.

| Field | Value | What it means |
|---|---|---|
| `intended_release_family` | **Zurich** | the family this candidate is **built for** |
| `observed_on` | `null` | the family something actually **ran on** — nothing has run anywhere |
| `documented_availability_floors` | Washington DC / Zurich P4 | where a mechanism first **appears** |

**The intended target is sourced, not chosen.** Zurich is the newest release
family named anywhere in the authoritative references pinned in the same file:
the Build Agent documentation is served under `/docs/r/zurich/`, and the
feasibility pass records the guided BYOLLM UI as available since Zurich P4.
Building for the newest family our own sourced references document is the
choice the record supports. `../test/packaging.test.js` enforces both halves —
the pin may not be null, and at least one of its sources must actually name the
family it is offered as evidence for.

`release.json` also carries an `intended_family_is_not` list, and it is
load-bearing rather than throat-clearing. The pin is **not** a claim that Zurich
is the current GA family (not verified here), **not** a claim that anything has
been built or tested on it, and **not** a claim that the preprocessor lane this
directory implements exists there — that is
`contracts/instance-contracts.json` → `H1-extension-point-exists`, still
`instance-pending`.

If the instance that eventually lands is a different family, **that difference
is itself a finding.** Record it in `observed_on`; do not quietly restate the
intended target as the tested one.

## Versioning

`../VERSION` tracks the Store application and moves **independently of the kit's
own `VERSION`**. A kit release does not imply a Store release, and a Store
release does not imply a kit release. Do not derive one from the other.
