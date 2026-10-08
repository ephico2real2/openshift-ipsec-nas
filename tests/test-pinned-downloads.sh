#!/bin/bash
# What CI downloads and runs is named by what it IS, not by a name that can be moved: an image by its digest, an
# action by its commit. (helm's archive is checked against its sha256 in the workflow itself; diagram-kit is this
# project's own, by tag.) Run from the repository root: tests/test-pinned-downloads.sh
set -uo pipefail
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

images="$(grep -hoE '(quay\.io|docker\.io|ghcr\.io|registry\.[a-z.]+)/[^" ]+' tests/test-*.sh | sort -u)"
loose="$(grep -v '@sha256:[0-9a-f]\{64\}$' <<<"${images}" || true)"
[[ -n "${images}" && -z "${loose}" ]] && ok "every image a test runs is named by digest: $(tr '\n' ' ' <<<"${images}")" \
  || bad "an image a test runs is named by a tag alone: $(tr '\n' ' ' <<<"${loose}")"

actions="$(grep -hE '^ *(- )?uses: ' .github/workflows/*.yml | sed 's/^ *\(- \)\{0,1\}uses: *//; s/ *#.*//' | grep -v '^ephico2real2/diagram-kit/' | sort -u)"
loose="$(grep -v '@[0-9a-f]\{40\}$' <<<"${actions}" || true)"
[[ -n "${actions}" && -z "${loose}" ]] && ok "every action is named by its commit: $(tr '\n' ' ' <<<"${actions}")" \
  || bad "an action is named by a tag or a branch: $(tr '\n' ' ' <<<"${loose}")"

[[ ${fails} -eq 0 ]] || { echo "${fails} failed"; exit 1; }
