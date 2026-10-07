#!/bin/bash
# scripts/perses-dashboard.sh writes its five files together or not at all, and leaves nothing temporary behind.
# No percli, no container and no cluster: the script runs on a COPY of the files it reads and writes, with a
# stand-in for perses-dashboard that can be told to fail on its first or its second conversion.
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
mv "$2.stand-in" "$2"
EOF
chmod +x "${work}/bin/perses-dashboard"

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
  rm -f "${work}/count"
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
done

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
