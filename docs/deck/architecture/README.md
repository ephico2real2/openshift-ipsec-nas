# Deck — IPsec to the NAS: Architecture and Design

The source of the architecture and design deck: 15 slides on our in-house DaemonSet, its Prometheus metrics, the dashboard in Perses and Grafana, why a dashboard is critical for NAS encryption, self-service, and Dynatrace and other APMs. It summarizes [doc 74](../../74-architecture-and-design-guide.md); every number on a slide comes from it and the docs it cites. The companion deck, on why Option B and the plan, is [`../option-b/`](../option-b/README.md).

The deck is a Slides artifact on claude.ai, which presents it and exports it as PDF or PowerPoint ([below](#export-as-pdf-or-powerpoint)). These files are its source, kept here so the deck is versioned with the docs. A change goes into both: edit the slide here, and publish the same file to the deck.

## Export as PDF or PowerPoint

From the deck's page on claude.ai: open the **Share** menu, then **Export**, and pick the format.

| Format | Use it for | What to know |
|---|---|---|
| **PDF** | Presenting, sending, printing | Looks exactly like the deck: the export fetches the deck's typefaces itself |
| **PowerPoint (.pptx), editable** | Editing in PowerPoint | Names the typefaces IBM Plex Sans and JetBrains Mono: install both from Google Fonts first, or the spacing can shift |
| **PowerPoint (.pptx), basic fonts** | Editing on any computer | Arial and Courier New in their place: the same look everywhere, slightly different from the deck |
| **PowerPoint, slides as pictures** (where the Export tab offers it) | Showing exactly as designed | Every slide an image: no editable text |

The deck is private until shared from the same Share menu; an exported file can go to anyone.

## Files

| File | What it is |
|---|---|
| `deck.json` | The index: title, slide order, the four sections, the two typefaces |
| `slides/<id>.html` | One slide per file: a single `<section>` on a 1920 × 1080 canvas, inline styles only, speaker notes in its `<aside>` |
| `images/` | The three screenshot crops made for the slides (from the full-dashboard captures, below) |

| # | Slide | Section |
|---|---|---|
| 1 | `cover` | The north star: every node its own certificate, tunnel and report |
| 2 | `north-star` | |
| 3 | `daemonset` | Our in-house DaemonSet and its Prometheus metrics |
| 4 | `design-rules` | |
| 5 | `metrics` | |
| 6 | `alerts` | |
| 7 | `architecture` | From the node to every dashboard, and why the dashboard matters |
| 8 | `dashboard` | |
| 9 | `two-viewers` | |
| 10 | `why-critical` | |
| 11 | `at-scale` | |
| 12 | `self-service` | |
| 13 | `apm` | Integration with Dynatrace and other APMs, and where we stand |
| 14 | `measured` | |
| 15 | `closing` | |

## Images

The slides refer to their images by the deck's asset URLs (`/_blob/<id>`), which resolve only in the deck. Each is a file in this repository:

| Asset in the slides | File in the repository | Slide |
|---|---|---|
| `/_blob/0cf80c60a6ff34c82f75defcd600da43` | [`diagrams/option-b-workflow/option-b-onboarding.light.png`](../../diagrams/option-b-workflow/option-b-onboarding.light.png) | `north-star` |
| `/_blob/df72471a14ea419c500f9d206bd7fd66` | [`diagrams/observability/observability.light.png`](../../diagrams/observability/observability.light.png) | `architecture` |
| `/_blob/c9f83c009d4e7d3b1d24869218e34396` | [`images/console-health.png`](images/console-health.png), cropped from [`images/crc/61-console-perses-two-tables.light.png`](../../images/crc/61-console-perses-two-tables.light.png) (1250 × 1000 from x 310, y 430) | `dashboard` |
| `/_blob/a25ae210e9667d6d1108f73a799e237b` | [`images/grafana-top.png`](images/grafana-top.png), cropped from [`images/crc/61-grafana-two-tables.light.png`](../../images/crc/61-grafana-two-tables.light.png) (1500 × 1250 from the top) | `two-viewers` |
| `/_blob/88e0f257260a0a5ddf94ef4a1e513a1b` | [`images/kind/dashboard-faults.light.png`](../../images/kind/dashboard-faults.light.png) | `at-scale` |
| `/_blob/2c4d4883e0466860c2bc1a72945bd467` | [`images/console-storage.png`](images/console-storage.png), cropped from [`images/crc/61-console-perses-two-tables.light.png`](../../images/crc/61-console-perses-two-tables.light.png) (1250 × 790 from x 310, y 2640) | `self-service` |
| `/_blob/128fc4cf66d43ed66b17aa1cf8918564` | [`images/dynatrace/ipsec-nas-metrics-in-dynatrace.png`](../../images/dynatrace/ipsec-nas-metrics-in-dynatrace.png) | `apm` |

The crops were made with `sips -c <height> <width> --cropOffset <y> <x>` on macOS. When a source image changes, crop it again, upload it to the deck and replace its asset URL in the slide.

## State

Identical to the deck at its version 5 (2026-10-08), as published. No enterprise host names, addresses or Venafi details.
