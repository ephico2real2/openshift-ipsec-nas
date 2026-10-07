#!/bin/bash
# scripts/perses-dashboard.sh writes its five files together or not at all, and leaves nothing temporary behind.
# No percli, no container and no cluster: the script runs on a COPY of the files it reads and writes, with a
# stand-in for perses-dashboard that can be told to fail on its first or its second conversion, and a stand-in for mv
# that can be told to fail, or to stop the script, at one of the five moves that end it.
# Run from the repository root: tests/test-perses-dashboard-script.sh
set -uo pipefail
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
GENERATED=(charts/ipsec-nas/files/ipsec-nas.perses.json
           manifests/option-b-per-node-certs/33-perses-dashboard.yaml
           manifests/option-b-per-node-certs/30-grafana-dashboard.yaml
           charts/ipsec-nas-option-c-metrics/files/ipsec-nas-option-c.json
           charts/ipsec-nas-option-c-metrics/files/ipsec-nas-option-c.perses.json)

# The stand-in: perses-dashboard <grafana.json> <out.json> ...; it writes the title of the Grafana file as JSON, the
# way the real one writes (beside the target, then moved), and fails on its call number FAIL_ON.
mkdir "${work}/bin"
cat > "${work}/bin/perses-dashboard" <<'EOF'
#!/bin/bash
set -euo pipefail
n=$(( $(cat "${COUNT_FILE}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${COUNT_FILE}"
if [[ "${n}" == "${FAIL_ON:-0}" ]]; then echo "perses-dashboard: (stand-in) the conversion number ${n} fails" >&2; exit 1; fi
python3 -c 'import json, sys; print(json.dumps({"display": {"name": json.load(open(sys.argv[1]))["title"]}}, indent=2))' "$1" > "$2.stand-in"
/bin/mv "$2.stand-in" "$2"          # by its path: the mv on the PATH may be the stand-in below, which is the script's
echo "wrote $2 (24 panels)"         # what the real one says
EOF
chmod +x "${work}/bin/perses-dashboard"

# The stand-in for mv, for the script's last five commands: on its call number MV_FAIL_ON it fails; after its call
# number MV_TERM_AFTER it sends the script SIGTERM, as a kill between two moves would.
mkdir "${work}/mvbin"
cat > "${work}/mvbin/mv" <<'EOF'
#!/bin/bash
n=0; [[ -f "${MV_COUNT_FILE}" ]] && read -r n < "${MV_COUNT_FILE}"; n=$((n + 1)); echo "${n}" > "${MV_COUNT_FILE}"
if [[ "${n}" == "${MV_FAIL_ON:-0}" ]]; then echo "mv: (stand-in) the move number ${n} fails" >&2; exit 1; fi
/bin/mv "$@" || exit 1
if [[ "${n}" == "${MV_TERM_AFTER:-0}" ]]; then kill -TERM "${PPID}"; /bin/sleep 1; fi
EOF
chmod +x "${work}/mvbin/mv"

fresh() {   # a new copy of what the script reads and writes, with one edit of the source that every file must follow
  rm -rf "${work}/repo"; mkdir "${work}/repo"
  tar -cf - scripts/perses-dashboard.sh scripts/option-c-dashboard.py charts/ipsec-nas/files/ipsec-nas.json "${GENERATED[@]}" \
    | tar -xf - -C "${work}/repo"
  python3 - "${work}/repo/charts/ipsec-nas/files/ipsec-nas.json" "$@" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]); dashboard = json.loads(path.read_text())
dashboard["description"] = "edited by tests/test-perses-dashboard-script.sh"
if "--other-uid" in sys.argv:
    dashboard["uid"] = "not-ipsec-nas"            # scripts/option-c-dashboard.py refuses it
path.write_text(json.dumps(dashboard, indent=2) + "\n")
PY
  rm -f "${work}/count" "${work}/mvcount"
}
state() { ( cd "${work}/repo" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 ); }
five() { ( cd "${work}/repo" && shasum -a 256 "${GENERATED[@]}" ); }
run() {     # run <FAIL_ON>: the script in the copy; its exit code is the result
  ( cd "${work}/repo" && PERSES_DASHBOARD="${work}/bin/perses-dashboard" COUNT_FILE="${work}/count" FAIL_ON="$1" \
      PERCLI=stand-in bash scripts/perses-dashboard.sh >"${work}/out" 2>"${work}/err" )
}
left() { ( cd "${work}/repo" && find . -type f \( -name '*.tmp' -o -name '*.stand-in' \) | LC_ALL=C sort | tr '\n' ' ' ); }

fresh; before="$(five)"
if run 0; then
  changed=$(diff <(echo "${before}") <(five) | grep -c '^>')
  [[ ${changed} -eq 5 && -z "$(left)" ]] \
    && ok "both conversions succeed: the five generated files are written, nothing temporary is left" \
    || bad "both conversions succeed: ${changed} of 5 files written, left behind: $(left)"
else
  bad "both conversions succeed: the script failed: $(cat "${work}/err")"
fi

for case in "1:Option B's conversion fails" "2:Option B converts and Option C's conversion fails"; do
  fresh; before="$(state)"
  if run "${case%%:*}"; then bad "${case#*:}: the script did not fail"; continue; fi
  [[ "$(state)" == "${before}" ]] \
    && ok "${case#*:}: no file of the repository has changed, nothing temporary is left" \
    || bad "${case#*:}: files changed or left behind: $(diff <(echo "${before}") <(state) | sed -n 's/^[<>] [0-9a-f]*  //p' | LC_ALL=C sort -u | tr '\n' ' ')"
  # Nothing was written, so nothing may be said to have been: the kit's own "wrote <target>.tmp" is not "wrote <target>".
  grep -q '^wrote ' "${work}/out" \
    && bad "${case#*:}: the script says it wrote a file: $(grep '^wrote ' "${work}/out" | tr '\n' ' ')" \
    || ok "${case#*:}: the script does not say it wrote a file"
done

# The first of the five moves fails: no move has been made, so every file is as it was. This is the case that shows a
# file written straight to its place by the LAST step before the moves (Option C's Perses file), which no failing
# conversion can show.
fresh; before="$(state)"
if ( cd "${work}/repo" && PATH="${work}/mvbin:${PATH}" MV_COUNT_FILE="${work}/mvcount" MV_FAIL_ON=1 \
       PERSES_DASHBOARD="${work}/bin/perses-dashboard" COUNT_FILE="${work}/count" FAIL_ON=0 PERCLI=stand-in \
       bash scripts/perses-dashboard.sh >"${work}/out" 2>"${work}/err" ); then
  bad "the first move fails: the script did not fail"
else
  [[ "$(state)" == "${before}" ]] \
    && ok "the first move fails: no file of the repository has changed, nothing temporary is left" \
    || bad "the first move fails: files changed or left behind: $(diff <(echo "${before}") <(state) | sed -n 's/^[<>] [0-9a-f]*  //p' | LC_ALL=C sort -u | tr '\n' ' ')"
fi

# SIGTERM between the first move and the second: the five moves are one step, and all of them are made.
fresh; before="$(five)"
( cd "${work}/repo" && PATH="${work}/mvbin:${PATH}" MV_COUNT_FILE="${work}/mvcount" MV_TERM_AFTER=1 \
    PERSES_DASHBOARD="${work}/bin/perses-dashboard" COUNT_FILE="${work}/count" FAIL_ON=0 PERCLI=stand-in \
    bash scripts/perses-dashboard.sh >"${work}/out" 2>"${work}/err" )
changed=$(diff <(echo "${before}") <(five) | grep -c '^>')
[[ ${changed} -eq 5 && -z "$(left)" ]] \
  && ok "SIGTERM between two moves: the five files are written all the same, nothing temporary is left" \
  || bad "SIGTERM between two moves: ${changed} of 5 files written, left behind: $(left)"

fresh --other-uid; before="$(state)"
if run 0; then
  bad "scripts/option-c-dashboard.py refuses the source: the script did not fail"
else
  [[ "$(state)" == "${before}" ]] \
    && ok "scripts/option-c-dashboard.py refuses the source: no file of the repository has changed, nothing temporary is left" \
    || bad "scripts/option-c-dashboard.py refuses the source: files changed or left behind: $(diff <(echo "${before}") <(state) | sed -n 's/^[<>] [0-9a-f]*  //p' | LC_ALL=C sort -u | tr '\n' ' ')"
fi

fresh; mkdir "${work}/path"; ln -s "${work}/bin/perses-dashboard" "${work}/path/perses-dashboard"
( cd "${work}/repo" && PATH="${work}/path:${PATH}" PERSES_DASHBOARD=perses-dashboard COUNT_FILE="${work}/count" FAIL_ON=0 \
    PERCLI=stand-in bash scripts/perses-dashboard.sh >"${work}/out" 2>"${work}/err" ) \
  && ok "PERSES_DASHBOARD may be the name of a command on the PATH" \
  || bad "PERSES_DASHBOARD=perses-dashboard, on the PATH: $(cat "${work}/err")"

[[ ${fails} -eq 0 ]] || { echo "${fails} failed"; exit 1; }
