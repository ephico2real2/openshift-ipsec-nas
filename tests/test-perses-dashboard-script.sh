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
# number MV_TERM_AFTER it sends the script SIGTERM, as a kill between two moves would. With MV_SIGNAL_GROUP_AFTER and
# MV_SIGNAL it sends that signal to the script's whole process group, itself included, as Ctrl-C at a terminal does.
# After its call number MV_FILL_AFTER it fills the FIFO MV_FILL, so that the next thing written to it blocks.
mkdir "${work}/mvbin"
cat > "${work}/mvbin/mv" <<'EOF'
#!/bin/bash
n=0; [[ -f "${MV_COUNT_FILE}" ]] && read -r n < "${MV_COUNT_FILE}"; n=$((n + 1)); echo "${n}" > "${MV_COUNT_FILE}"
if [[ "${n}" == "${MV_FAIL_ON:-0}" ]]; then echo "mv: (stand-in) the move number ${n} fails" >&2; exit 1; fi
/bin/mv "$@" || exit 1
if [[ "${n}" == "${MV_TERM_AFTER:-0}" ]]; then kill -TERM "${PPID}"; /bin/sleep 1; fi
if [[ "${n}" == "${MV_SIGNAL_GROUP_AFTER:-0}" ]]; then kill "-${MV_SIGNAL}" -- "-${PPID}"; /bin/sleep 1; fi
if [[ "${n}" == "${MV_FILL_AFTER:-0}" ]]; then
  python3 -c 'import os, sys
fifo = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
try:
    while True: os.write(fifo, b"\0")
except BlockingIOError: pass' "${MV_FILL}"
  : > "${MV_FILL}.full"
fi
exit 0
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

# The same for each signal a terminal or a supervisor sends, to the script's whole process group: the script leads a
# group of its own here (a new session), which is the group the stand-in signals. A script that holds off TERM alone
# passed the case above.
for sig in INT TERM HUP; do
  fresh; before="$(five)"
  ( cd "${work}/repo" && PATH="${work}/mvbin:${PATH}" MV_COUNT_FILE="${work}/mvcount" MV_SIGNAL_GROUP_AFTER=2 MV_SIGNAL="${sig}" \
      PERSES_DASHBOARD="${work}/bin/perses-dashboard" COUNT_FILE="${work}/count" FAIL_ON=0 PERCLI=stand-in \
      python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      bash scripts/perses-dashboard.sh >"${work}/out" 2>"${work}/err" )
  changed=$(diff <(echo "${before}") <(five) | grep -c '^>')
  [[ ${changed} -eq 5 && -z "$(left)" ]] \
    && ok "SIG${sig} to the group between two moves: the five files are written all the same, nothing temporary is left" \
    || bad "SIG${sig} to the group between two moves: ${changed} of 5 files written, left behind: $(left)"
done

# Once the moves are done the signals are the script's to take again. Its output is a FIFO here that is full and that
# nobody reads, so it blocks as it says what it wrote: SIGTERM must end it. (Held off to the end, KILL alone did.)
# Not under bash 3.2, which does not act on one signal while a builtin of its is blocked, held off or not.
if (( $(bash -c 'echo "${BASH_VERSINFO[0]}"') >= 4 )); then
  fresh; before="$(five)"; mkfifo "${work}/fifo"; exec 8<>"${work}/fifo"
  ( cd "${work}/repo" && PATH="${work}/mvbin:${PATH}" MV_COUNT_FILE="${work}/mvcount" MV_FILL_AFTER=5 MV_FILL="${work}/fifo" \
      PERSES_DASHBOARD="${work}/bin/perses-dashboard" COUNT_FILE="${work}/count" FAIL_ON=0 PERCLI=stand-in \
      exec bash scripts/perses-dashboard.sh >"${work}/fifo" 2>"${work}/err" ) &
  blocked=$!
  for _ in $(seq 1 100); do [[ -f "${work}/fifo.full" ]] && break; sleep 0.1; done
  sleep 1; changed=$(diff <(echo "${before}") <(five) | grep -c '^>')
  kill -TERM "${blocked}" 2>/dev/null; sleep 2
  if kill -0 "${blocked}" 2>/dev/null; then
    kill -KILL "${blocked}"
    bad "after the moves (${changed} of 5 files written) SIGTERM did not end the script: its signals are still held off"
  else
    [[ ${changed} -eq 5 ]] && ok "after the moves the signals are the script's again: SIGTERM ends it, the five files written" \
      || bad "the script ended before its five moves: ${changed} of 5 files written: $(cat "${work}/err")"
  fi
  wait "${blocked}" 2>/dev/null; exec 8<&-; rm -f "${work}/fifo" "${work}/fifo.full"
else
  printf 'skip  the signals after the moves (bash %s)\n' "$(bash -c 'echo "${BASH_VERSION}"')"
fi

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
