# Deck — Option B: Per-Node IPsec to the NAS

The source of the presentation deck on Option B: 17 slides, for the storage, PKI, security and platform teams. It summarizes [doc 70](../../70-review-enterprise-linux-ipsec-config.md), [doc 71](../../71-option-b-nas-team-engagement.md), [doc 72](../../72-option-b-implementation-plan.md) and [doc 73](../../73-runbook-node-certificate-revocation.md); every number on a slide comes from them.

The deck is a Slides artifact on claude.ai, which presents it and exports it as PDF or PowerPoint (Share › Export). These files are its source, kept here so the deck is versioned with the docs it summarizes. A change goes into both: edit the slide here, and publish the same file to the deck.

## Files

| File | What it is |
|---|---|
| `deck.json` | The deck's index: title, slide order, the four sections, the two typefaces (IBM Plex Sans, JetBrains Mono) |
| `slides/<id>.html` | One slide per file: a single `<section>` on a 1920 × 1080 canvas, inline styles only, speaker notes in its `<aside>` |

Slide order, from `deck.json`:

| # | Slide | Section |
|---|---|---|
| 1 | `cover` | The requirement, and why an OpenShift node is not a Linux server |
| 2 | `standard` | |
| 3 | `rhcos` | |
| 4 | `redhat` | |
| 5 | `odd-even` | |
| 6 | `why-automation` | Why each node needs its own certificate, and why Options A and C do not fit |
| 7 | `not-a-or-c` | |
| 8 | `overview` | How Option B works, end to end |
| 9 | `mechanism` | |
| 10 | `onboarding` | |
| 11 | `lifecycle` | |
| 12 | `components` | |
| 13 | `monitoring` | |
| 14 | `nncp` | The PoC and what we need from each team |
| 15 | `poc` | |
| 16 | `asks` | |
| 17 | `next` | |

## Images

The slides refer to their images by the deck's asset URLs (`/_blob/<id>`), which resolve only in the deck. Each is a copy of a diagram in this repository (the light version):

| Asset in the slides | Diagram in the repository | Slide |
|---|---|---|
| `/_blob/38e4f1e416d2f1d08f3b090d1d34147d` | [`diagrams/option-b-workflow/option-b-why-automation.light.png`](../../diagrams/option-b-workflow/option-b-why-automation.light.png) | `why-automation` |
| `/_blob/102befd8fe192f9fbe00a32a291f0e3c` | [`diagrams/ipsec-nas/overview.light.png`](../../diagrams/ipsec-nas/overview.light.png) | `overview` |
| `/_blob/43a491bc868e5950b4f79f82678c8377` | [`diagrams/ipsec-nas/option-b-per-node-certs.light.png`](../../diagrams/ipsec-nas/option-b-per-node-certs.light.png) | `mechanism` |
| `/_blob/7be70a806ac044ed450d5d41d3881f0c` | [`diagrams/option-b-workflow/option-b-onboarding.light.png`](../../diagrams/option-b-workflow/option-b-onboarding.light.png) | `onboarding` |
| `/_blob/626bcdf09f791fa56b634b9937cbb419` | [`diagrams/option-b-workflow/option-b-lifecycle.light.png`](../../diagrams/option-b-workflow/option-b-lifecycle.light.png) | `lifecycle` |
| `/_blob/53a49c479a400d00728b2087bef1a5cd` | [`diagrams/ipsec-nas/perses-dashboard.light.png`](../../diagrams/ipsec-nas/perses-dashboard.light.png) | `monitoring` |

When a diagram is re-rendered, upload the new PNG to the deck and replace its asset URL in the slide.

## State

Identical to the deck at its version 14 (2026-10-08): all 18 files were downloaded from the deck and compared byte for byte. Slide 7 (`not-a-or-c`) is the deck editor's re-save of the original, kept as it is in the deck. Enterprise host names, addresses and Venafi details are left out, as in the docs.
