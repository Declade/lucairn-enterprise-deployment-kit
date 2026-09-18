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

## The target release

`release.json` records `release_family: null` with `status: "NOT PINNED"`.

This is deliberate and it is not an omission. No instance with Now Assist skills
has been available, and the evaluation-instance request asks the vendor for the
instance's release family and patch level precisely because it cannot be known
in advance. Every mechanism this application depends on is release-sensitive, so
naming a family here would be a guess that later reads as a tested target.

What *is* pinned is a documented **availability floor** for the Custom-LLM lane
(`Washington DC`, guided BYOLLM UI since `Zurich P4`), sourced to the feasibility
findings. A floor says where a mechanism appears. It does not say which release
this application was built for, and it says nothing at all about the
preprocessor lane this directory implements — which has no published floor of
its own.

## Versioning

`../VERSION` tracks the Store application and moves **independently of the kit's
own `VERSION`**. A kit release does not imply a Store release, and a Store
release does not imply a kit release. Do not derive one from the other.
