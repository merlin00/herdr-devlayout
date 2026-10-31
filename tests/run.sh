#!/bin/sh
# devlayout tests: check open / build / repair / reset flows against a fake herdr (tests/mock-herdr).
# shellcheck disable=SC2016,SC2034  # check() evals its condition string, so single quotes are intended
# Run: sh tests/run.sh      (needs python3 and jq)
# The fake herdr follows the real 0.9.5 output for the fields devlayout reads; it cannot check real shell
# timing, agent detection or process names.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
DL=$ROOT/bin/devlayout
MOCK=$HERE/mock-herdr
pass=0; fail=0

# All test files live under one temp dir, removed on exit (paths stay short for the 104-byte socket limit)
TROOT=$(mktemp -d); tn=0
trap 'rm -rf "$TROOT"' EXIT
trap 'exit 1' INT TERM
# Stop a background helper quietly (no "Terminated" line from the shell)
stop_bg() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# ── setup ──
setup() {   # $1 = project directory name
  tn=$((tn + 1)); T=$TROOT/$tn; mkdir "$T"
  PROJ=$T/$1; mkdir -p "$PROJ"
  export MOCK_STATE="$T/state.json"
  export HERDR_BIN_PATH="$MOCK"
  export HERDR_PLUGIN_STATE_DIR="$T/state"
  export HERDR_PLUGIN_CONFIG_DIR="$T/config"
  export HERDR_ENV=1
  export HERDR_PANE_ID=w1:p1
  export HERDR_PLUGIN_ROOT="$ROOT"
  unset HERDR_ACTIVE_PANE_ID HERDR_ACTIVE_PANE_CWD DEVLAYOUT_DEBUG 2>/dev/null || :
  mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
}
# $1 = labels (comma separated, empty = null) $2 = agent values (comma) $3 = tabs (comma, e.g. t1,t1,t2; default all t1)
state_panes() {
  python3 - "$MOCK_STATE" "$PROJ" "$1" "${2:-}" "${3:-}" <<'EOF'
import json, sys
path, proj, labels, agents, tabs = sys.argv[1:6]
labels = labels.split(",")
agents = (agents.split(",") if agents else [""] * len(labels))
tabs = (tabs.split(",") if tabs else ["t1"] * len(labels))
panes = []
for i, (l, a, t) in enumerate(zip(labels, agents, tabs), 1):
    panes.append({"pane_id": f"w1:p{i}", "workspace_id": "w1", "tab_id": f"w1:{t}",
                  "label": l or None, "agent": a or None, "cwd": proj, "focused": i == 1})
json.dump({"workspaces": [{"workspace_id": "w1", "label": proj.rsplit("/", 1)[1], "active_tab_id": "w1:t1"}],
           "panes": panes, "runs": []}, open(path, "w"))
EOF
}
# Several workspaces/tabs: one argument per pane, "pane_id|tab_id|label|cwd" (empty label = null)
state_multi() {
  python3 - "$MOCK_STATE" "$@" <<'EOF'
import json, sys
path, specs = sys.argv[1], sys.argv[2:]
panes, wss = [], {}
for sp in specs:
    pid, tab, label, cwd = sp.split("|")
    ws = pid.split(":")[0]
    wss.setdefault(ws, {"workspace_id": ws, "label": cwd.rstrip("/").rsplit("/", 1)[1], "active_tab_id": tab})
    panes.append({"pane_id": pid, "workspace_id": ws, "tab_id": tab, "label": label or None,
                  "agent": None, "cwd": cwd, "focused": False})
json.dump({"workspaces": list(wss.values()), "panes": panes, "runs": []}, open(path, "w"))
EOF
}
# Pane ids of a tab (comma separated)
tab_panes() { jq -r --arg t "$1" '[.panes[] | select(.tab_id == $t) | .pane_id] | sort | join(",")' "$MOCK_STATE"; }
q() { jq -r "$1" "$MOCK_STATE"; }
# Set a pane field: $1=pane $2=key $3=JSON value (e.g. set_pane w1:p3 fg '"vim"')
set_pane() {
  _tmp=$MOCK_STATE.tmp
  jq --arg p "$1" --arg k "$2" --argjson v "$3" '(.panes[] | select(.pane_id == $p))[$k] = $v' "$MOCK_STATE" >"$_tmp" && mv "$_tmp" "$MOCK_STATE"
}
runs_for() { jq -r --arg p "$1" '[.runs[] | select(.pane == $p) | .text] | join("\n")' "$MOCK_STATE"; }
nruns() { q '.runs | length'; }
# Project state key (pid / lock / socket file name) = the editor-socket file name without .sock
key_of() { _k=$("$DL" editor-socket "$1"); _k=${_k##*/}; printf '%s\n' "${_k%.sock}"; }
# Pid file path from the command typed into a pane (sh -c '<echo $$ > path; ...>')
pidpath_from_run() {
  python3 -c 'import shlex,sys; inner=shlex.split(sys.argv[1])[2]; print(shlex.split(inner.split(";")[0])[-1])' "$(runs_for "$1" | tail -n1)"
}

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "condition: $2"; fi; }

# Everything typed must be valid shell syntax (it goes straight into the pane's shell)
all_runs_parse() {
  # Check both the outer line (typed into the user's shell) and the code inside sh -c with sh -n
  jq -r '.runs[].text' "$MOCK_STATE" | while IFS= read -r _t; do
    sh -n -c "$_t" || exit 1
    _inner=$(python3 -c 'import shlex,sys; a=shlex.split(sys.argv[1]); print(a[2])' "$_t") || exit 1
    sh -n -c "$_inner" || exit 1
  done
}

echo "devlayout tests"

# T1 running outside herdr is an error
setup proj; state_panes ""
unset HERDR_ENV
out=$("$DL" open 2>&1); rc=$?
check "outside herdr -> error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "run this inside herdr"'

# T2 workspace with 1 pane -> build the layout in place
setup proj; state_panes ""
out=$("$DL" 2>&1); rc=$?
check "1 pane -> exits 0" '[ $rc -eq 0 ]'
check "1 pane -> 3 panes" '[ "$(q ".panes | length")" = 3 ]'
check "1 pane -> labels (p1 claude, p2 reviewr, p3 nvim)" '[ "$(q "[.panes[] | .label] | join(\",\")")" = "claude,reviewr,nvim" ]'
check "1 pane -> review is the right split" '[ "$(q ".panes[] | select(.pane_id==\"w1:p2\") | .split_dir")" = right ]'
check "1 pane -> editor is split below the agent" '[ "$(q ".panes[] | select(.pane_id==\"w1:p3\") | .split_dir + \"/\" + .split_from")" = "down/w1:p1" ]'
check "1 pane -> editor started (nvim --listen)" 'runs_for w1:p3 | grep -q "exec nvim --listen"'
check "1 pane -> review started" 'runs_for w1:p2 | grep -q "exec herdr-reviewr"'
check "1 pane -> new agent (claude, not --continue)" 'runs_for w1:p1 | grep -q "exec claude" && ! runs_for w1:p1 | grep -q continue'
check "1 pane -> typed text is valid shell" 'all_runs_parse'

# T3 already 3 panes, all stopped -> start all three, the agent resumes
setup proj; state_panes "claude,reviewr,nvim"
out=$("$DL" open 2>&1); rc=$?
check "3 panes, all stopped -> 3 started" '[ $rc -eq 0 ] && [ "$(nruns)" = 3 ]'
check "3 panes -> agent resumes with --continue, new session on early failure" 'runs_for w1:p1 | grep -q "claude --continue ||" && runs_for w1:p1 | grep -q "\-lt 60"'
check "3 panes -> editor goes to the nvim pane" 'runs_for w1:p3 | grep -q "nvim --listen"'
check "3 panes -> typed text is valid shell" 'all_runs_parse'

# T4 the agent is detected -> leave the agent alone
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
out=$("$DL" 2>&1)
check "agent detected -> agent not started" '[ -z "$(runs_for w1:p1)" ] && [ "$(nruns)" = 2 ]'

# T5 repeated press: just started, so type nothing again (COOLDOWN)
setup proj; state_panes "claude,reviewr,nvim"
"$DL" >/dev/null 2>&1; n1=$(nruns)
out=$("$DL" 2>&1)
check "repeated press -> nothing typed the second time" '[ "$(nruns)" = "$n1" ] && printf %s "$out" | grep -q "all three programs are running"'

# T6 2 panes -> error that points to reset
setup proj; state_panes ",x"
out=$("$DL" 2>&1); rc=$?
check "2 panes -> error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q reset'

# T7 3 unlabeled panes -> roles by creation order (id form w1:pN)
setup proj; state_panes ",,"
out=$("$DL" 2>&1)
check "no labels -> labels by creation order" '[ "$(q "[.panes[] | .label] | join(\",\")")" = "claude,reviewr,nvim" ]'
check "no labels -> editor is p3" 'runs_for w1:p3 | grep -q "nvim --listen"'

# T8 reset: 4 panes, claude is p3 -> close the others and rebuild
setup proj; state_panes "x,y,claude,z"
export HERDR_PANE_ID=w1:p2
out=$("$DL" reset 2>&1); rc=$?
check "reset -> succeeds" '[ $rc -eq 0 ]'
check "reset -> 3 panes" '[ "$(q ".panes | length")" = 3 ]'
check "reset -> claude pane keeps its id p3" '[ "$(q ".panes[] | select(.label==\"claude\") | .pane_id")" = w1:p3 ]'
check "reset -> new pane ids p5, p6 (no reuse)" '[ "$(q "[.panes[] | .pane_id] | sort | join(\",\")")" = "w1:p3,w1:p5,w1:p6" ]'
check "reset -> agent resumes" 'runs_for w1:p3 | grep -q "claude --continue"'

# T9 open DIR: create the missing workspace
setup newproj
python3 -c "import json;json.dump({'workspaces':[],'panes':[],'runs':[]},open('$MOCK_STATE','w'))"
out=$("$DL" open "$PROJ" 2>&1); rc=$?
check "open DIR -> workspace created (label = folder name)" '[ $rc -eq 0 ] && [ "$(q ".workspaces[0].label")" = newproj ]'
check "open DIR -> 3 panes" '[ "$(q ".panes | length")" = 3 ]'

# T10 bad arguments
setup proj; state_panes ""
out=$("$DL" --bogus 2>&1); rc=$?
check "unknown option -> error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "unknown option"'
out=$("$DL" /no/such/dir 2>&1); rc=$?
check "missing directory -> error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "no such directory"'

# T11 review alive by pid -> do not start it again
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
echo "DEVLAYOUT_REVIEW_CMD='sleep 30'" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
mkdir -p "$HERDR_PLUGIN_STATE_DIR/run"
sleep 30 & sp=$!
echo "$sp" >"$HERDR_PLUGIN_STATE_DIR/run/$(key_of "$PROJ").review.pid"
out=$("$DL" 2>&1)
check "review pid alive -> review not started" '[ -z "$(runs_for w1:p2)" ] && [ -n "$(runs_for w1:p3)" ]'
# a pid that now belongs to another program (reused) counts as stopped
echo "$$" >"$HERDR_PLUGIN_STATE_DIR/run/$(key_of "$PROJ").review.pid"
rm -f "$HERDR_PLUGIN_STATE_DIR"/run/*.started
state_panes "claude,reviewr,nvim" "claude,,"
out=$("$DL" 2>&1)
check "pid of another process -> review started again" '[ -n "$(runs_for w1:p2)" ]'
stop_bg "$sp"

# T12 path with special characters (space, single quote)
setup "it's my proj"; state_panes ""
out=$("$DL" 2>&1); rc=$?
check "special characters -> succeeds" '[ $rc -eq 0 ]'
check "special characters -> typed text is valid shell" 'all_runs_parse'
check "special characters -> socket path included" 'runs_for w1:p3 | grep -q "my proj-[0-9a-f]\{8\}\.sock"'

# T13 lock against concurrent runs
setup proj; state_panes ""
mkdir -p "$HERDR_PLUGIN_STATE_DIR/run/$(key_of "$PROJ").lock"
out=$("$DL" 2>&1); rc=$?
check "lock held -> error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "in progress"'

# T14 replace the agent via config
setup proj; state_panes ""
printf '%s\n' "DEVLAYOUT_AGENT_CMD=codex" "DEVLAYOUT_AGENT_NAME=codex" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
"$DL" >/dev/null 2>&1
check "config: agent command replaced" 'runs_for w1:p1 | grep -q "exec codex"'

# T15 status
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
out=$("$DL" status 2>&1); rc=$?
check "status output" '[ $rc -eq 0 ] && printf %s "$out" | grep -q "agent   running"'

# T16 really run the resume command: --continue failing at once starts a new agent; exiting later does not
setup proj; state_panes "claude,reviewr,nvim"
FAKE=$T/bin; mkdir -p "$FAKE"
cat >"$FAKE/claude" <<'EOS'
#!/bin/sh
if [ "${1:-}" = --continue ]; then [ -f "$CONT_OK" ] && { echo RESUMED; exit 3; }; exit 1; fi
echo NEW
EOS
chmod +x "$FAKE/claude"
"$DL" >/dev/null 2>&1
code=$(python3 -c 'import shlex,sys; print(shlex.split(sys.argv[1])[2])' "$(runs_for w1:p1)")
res=$(CONT_OK=$T/none PATH="$FAKE:$PATH" sh -c "$code")
check "resume fails (nothing to resume) -> new agent" '[ "$res" = NEW ]'
touch "$T/ok"
res=$(CONT_OK=$T/ok PATH="$FAKE:$PATH" sh -c "$(printf %s "$code" | sed "s/-lt 60/-lt 0/")")
check "resumed, then exits after the grace time -> no new agent" '[ "$res" = RESUMED ]'

# ── type only when the shell is in front ──

# T17 the user started vim in the editor pane (no pid file) -> do not type into the editor pane
setup proj; state_panes "claude,reviewr,nvim"
set_pane w1:p3 fg '"vim"'
t0=$(date +%s); out=$("$DL" 2>&1); rc=$?; t1=$(date +%s)
check "existing pane with vim in front -> skipped at once, no waiting" '[ $((t1 - t0)) -lt 3 ]'
check "vim in front -> nothing typed into editor" '[ $rc -eq 0 ] && [ -z "$(runs_for w1:p3)" ]'
check "vim in front -> the other two typed" '[ -n "$(runs_for w1:p1)" ] && [ -n "$(runs_for w1:p2)" ]'
check "vim in front -> skip message names vim" 'printf %s "$out" | grep -q "skipped: editor(vim)"'

# T18 Claude started by hand, not yet detected by herdr -> do not type into the agent pane (name is a version string)
setup proj; state_panes "claude,reviewr,nvim"
set_pane w1:p1 fg '"claude"'
out=$("$DL" 2>&1)
check "claude in front (not detected) -> nothing typed into agent" '[ -z "$(runs_for w1:p1)" ] && [ "$(nruns)" = 2 ]'
check "message uses argv0 claude (not the version string)" 'printf %s "$out" | grep -q "agent pane (w1:p1) is running claude;" && ! printf %s "$out" | grep -q 2.1.312'

# T19 shell state briefly unknown (starting) -> wait, then type
setup proj; state_panes "claude,reviewr,nvim"
echo "DEVLAYOUT_SHELL_WAIT=3" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
set_pane w1:p3 fg_unknown 2
out=$("$DL" 2>&1)
check "shell starting -> editor typed after waiting" '[ -n "$(runs_for w1:p3)" ]'

# T20 process-info fails -> play safe and type nothing
setup proj; state_panes "claude,reviewr,nvim"
echo "DEVLAYOUT_SHELL_WAIT=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
set_pane w1:p2 procinfo_fail true
out=$("$DL" 2>&1); rc=$?
check "process-info fails -> nothing typed into review" '[ $rc -eq 0 ] && [ -z "$(runs_for w1:p2)" ] && [ -n "$(runs_for w1:p3)" ]'
check "process-info fails -> message says so" 'printf %s "$out" | grep -q "could not confirm a shell prompt"'

# T21 a skipped role leaves no cooldown -> once the shell is back in front, the next run types
setup proj; state_panes "claude,reviewr,nvim"
set_pane w1:p3 fg '"vim"'
"$DL" >/dev/null 2>&1
set_pane w1:p3 fg null
out=$("$DL" 2>&1)
check "skipped, then shell back -> only editor typed" '[ -n "$(runs_for w1:p3)" ] && [ "$(nruns)" = 3 ]'

# T22 status shows the foreground program
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
set_pane w1:p3 fg '"vim"'
out=$("$DL" status 2>&1)
check "status -> foreground: vim" 'printf %s "$out" | grep "^editor" | grep -q "(foreground: vim)"'

# T22b a newly split pane may briefly have a child zsh in front while the shell starts -> wait instead of skipping
setup proj; state_panes ""
echo "DEVLAYOUT_SHELL_WAIT=3" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(MOCK_NEW_PANE_STARTING=2 "$DL" 2>&1); rc=$?
check "new pane shell starting -> editor and review typed after waiting" '[ $rc -eq 0 ] && [ -n "$(runs_for w1:p2)" ] && [ -n "$(runs_for w1:p3)" ] && ! printf %s "$out" | grep -q skipped'

# T22c role order of 3 unlabeled panes: ids go p9, pA … pZ, p0, p11 … (herdr base 32)
setup proj; state_panes ",,"
_tmp=$MOCK_STATE.tmp
jq '.panes[0].pane_id = "w1:p9" | .panes[1].pane_id = "w1:pA" | .panes[2].pane_id = "w1:pB"' "$MOCK_STATE" >"$_tmp" && mv "$_tmp" "$MOCK_STATE"
export HERDR_PANE_ID=w1:p9
out=$("$DL" 2>&1)
check "base-32 order (p9<pA<pB) -> agent p9, review pA, editor pB" '[ "$(q "[.panes[] | .pane_id + \"=\" + .label] | join(\",\")")" = "w1:p9=claude,w1:pA=reviewr,w1:pB=nvim" ] && runs_for w1:pB | grep -q "nvim --listen"'
setup proj; state_panes ",,"
jq '.panes[0].pane_id = "w1:p1Z" | .panes[1].pane_id = "w1:p10" | .panes[2].pane_id = "w1:p21"' "$MOCK_STATE" >"$_tmp" && mv "$_tmp" "$MOCK_STATE"
export HERDR_PANE_ID=w1:p1Z
out=$("$DL" 2>&1)
check "base-32 order (p1Z<p10<p21) -> agent p1Z" '[ "$(q ".panes[] | select(.label==\"claude\") | .pane_id")" = w1:p1Z ] && [ "$(q ".panes[] | select(.label==\"nvim\") | .pane_id")" = w1:p21 ]'
# reset still works when new pane ids use base 32 (pA after p9)
setup proj; state_panes "a,b,c,d,e,f,g,claude,x"
export HERDR_PANE_ID=w1:p9
out=$("$DL" reset 2>&1); rc=$?
check "reset -> new pane ids pA, pB" '[ $rc -eq 0 ] && [ "$(q "[.panes[] | .pane_id] | join(\",\")")" = "w1:p8,w1:pA,w1:pB" ]'

# ── only the current tab ──

# T23 tab 1 has the layout, tab 2 has 1 pane, current pane in tab 1 -> repair tab 1 (other tabs are not counted)
setup proj; state_panes "claude,reviewr,nvim,x" "" "t1,t1,t1,t2"
out=$("$DL" 2>&1); rc=$?
check "open in tab 1 -> repaired without error" '[ $rc -eq 0 ] && [ "$(nruns)" = 3 ]'
check "open in tab 1 -> tab 2 untouched" '[ "$(tab_panes w1:t2)" = w1:p4 ] && [ -z "$(runs_for w1:p4)" ]'

# T24 same state, current pane in tab 2 -> build only in tab 2
setup proj; state_panes "claude,reviewr,nvim,x" "" "t1,t1,t1,t2"
export HERDR_PANE_ID=w1:p4
out=$("$DL" 2>&1); rc=$?
check "open in tab 2 -> layout in tab 2" '[ $rc -eq 0 ] && [ "$(tab_panes w1:t2)" = "w1:p4,w1:p5,w1:p6" ]'
check "open in tab 2 -> tab 1 panes and labels untouched, nothing typed" '[ "$(tab_panes w1:t1)" = "w1:p1,w1:p2,w1:p3" ] && [ -z "$(runs_for w1:p1)$(runs_for w1:p2)$(runs_for w1:p3)" ]'

# T25 reset from tab 2: tab 1 has a claude label but must not be touched
setup proj; state_panes "claude,reviewr,nvim,y,z" "" "t1,t1,t1,t2,t2"
export HERDR_PANE_ID=w1:p5
out=$("$DL" reset 2>&1); rc=$?
check "reset in tab 2 -> succeeds" '[ $rc -eq 0 ]'
check "reset in tab 2 -> no tab 1 pane closed" '[ "$(tab_panes w1:t1)" = "w1:p1,w1:p2,w1:p3" ] && [ -z "$(runs_for w1:p1)" ]'
check "reset in tab 2 -> only tab 2 rebuilt (p4 kept)" '[ "$(q "[.panes[] | select(.tab_id==\"w1:t2\")] | length")" = 3 ] && printf %s "$(tab_panes w1:t2)" | grep -q "w1:p4"'

# T26 open <DIR>: work on the existing workspace's active tab
setup proj; state_panes "claude,reviewr,nvim,x" "" "t1,t1,t1,t2"
_tmp=$MOCK_STATE.tmp; jq '.workspaces[0].active_tab_id = "w1:t2"' "$MOCK_STATE" >"$_tmp" && mv "$_tmp" "$MOCK_STATE"
out=$("$DL" open "$PROJ" 2>&1); rc=$?
check "open DIR -> layout in the active tab (tab 2)" '[ $rc -eq 0 ] && [ "$(q "[.panes[] | select(.tab_id==\"w1:t2\")] | length")" = 3 ] && [ "$(tab_panes w1:t1)" = "w1:p1,w1:p2,w1:p3" ]'

# ── projects keyed by path ──

# T27 two projects with the same folder name (a/app, b/app): a's editor running must not stop b's editor from starting
setup a/app; state_panes "claude,reviewr,nvim" "claude,,"
echo "DEVLAYOUT_EDITOR_CMD='sleep 30'" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
"$DL" >/dev/null 2>&1
apid=$(pidpath_from_run w1:p3)
sleep 30 & sp=$!
echo "$sp" >"$apid"                      # a's editor is running
rm -f "$HERDR_PLUGIN_STATE_DIR"/run/*.started
PROJB=$T/b/app; mkdir -p "$PROJB"; PROJ=$PROJB; state_panes "claude,reviewr,nvim" "claude,,"
out=$("$DL" 2>&1)
check "same name, other path -> b's editor started" '[ -n "$(runs_for w1:p3)" ]'
check "the two projects use different pid files" '[ "$(pidpath_from_run w1:p3)" != "$apid" ]'
stop_bg "$sp"

# T28 socket path: <folder>-<8 hex path hash>.sock, different per project, same as the one open uses
setup a/app; state_panes ""
mkdir -p "$T/b/app"
sa=$("$DL" editor-socket "$PROJ"); sb=$("$DL" editor-socket "$T/b/app")
check "socket name app-<8hex>.sock" 'printf %s "$sa" | grep -q "/app-[0-9a-f]\{8\}\.sock$"'
check "same-named projects get different sockets" '[ "$sa" != "$sb" ]'
"$DL" >/dev/null 2>&1
check "open's nvim --listen path = editor-socket" 'runs_for w1:p3 | grep -qF "${sa##*/}"'

# T29 locks are per project too: a lock for the bare folder name does not block
setup b/app; state_panes ""
mkdir -p "$HERDR_PLUGIN_STATE_DIR/run/app.lock"
out=$("$DL" 2>&1); rc=$?
check "lock with only the same name -> runs" '[ $rc -eq 0 ] && [ "$(nruns)" = 3 ]'

# ── startup hook / repair-all ──
three() { printf '%s\n' "$1:p1|$1:t1|claude|$2" "$1:p2|$1:t1|reviewr|$2" "$1:p3|$1:t1|nvim|$2"; }

# T30 startup is off by default -> types nothing
setup proj; state_panes "claude,reviewr,nvim"; unset HERDR_PANE_ID
out=$("$DL" startup 2>&1); rc=$?
check "startup off by default -> nothing typed, exits 0" '[ $rc -eq 0 ] && [ "$(nruns)" = 0 ] && printf %s "$out" | grep -q "startup repair is off"'

# T31 on: in two workspaces with our layout, repair editor and review only; the agent is left to herdr
setup p1; P2=$T/p2; mkdir -p "$P2"; unset HERDR_PANE_ID
# shellcheck disable=SC2046
state_multi $(three w1 "$PROJ") $(three w2 "$P2")
echo "DEVLAYOUT_STARTUP=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$("$DL" startup 2>&1); rc=$?
check "startup -> editor and review typed in both workspaces" '[ $rc -eq 0 ] && [ -n "$(runs_for w1:p2)" ] && [ -n "$(runs_for w1:p3)" ] && [ -n "$(runs_for w2:p2)" ] && [ -n "$(runs_for w2:p3)" ]'
check "startup -> nothing typed into agent" '[ -z "$(runs_for w1:p1)$(runs_for w2:p1)" ]'
check "startup -> tab count summary" 'printf %s "$out" | grep -q "2 tab(s)"'

# T32 DEVLAYOUT_STARTUP_AGENT=1 -> the agent is resumed too
setup p1; unset HERDR_PANE_ID
# shellcheck disable=SC2046
state_multi $(three w1 "$PROJ")
printf '%s\n' DEVLAYOUT_STARTUP=1 DEVLAYOUT_STARTUP_AGENT=1 >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
"$DL" startup >/dev/null 2>&1
check "startup + AGENT=1 -> agent resume typed" 'runs_for w1:p1 | grep -q "claude --continue"'

# T33 tabs without our layout (3 unlabeled, 1 pane, 4 panes) are left alone
setup p1; unset HERDR_PANE_ID
state_multi "w1:p1|w1:t1||$PROJ" "w1:p2|w1:t1||$PROJ" "w1:p3|w1:t1||$PROJ" \
            "w1:p4|w1:t2||$PROJ" \
            "w1:p5|w1:t3|claude|$PROJ" "w1:p6|w1:t3|reviewr|$PROJ" "w1:p7|w1:t3|nvim|$PROJ" "w1:p8|w1:t3|x|$PROJ"
echo "DEVLAYOUT_STARTUP=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$("$DL" startup 2>&1); rc=$?
check "startup -> other tabs: no typing, labels or pane changes" '[ $rc -eq 0 ] && [ "$(nruns)" = 0 ] && [ "$(q ".panes | length")" = 8 ] && [ "$(q "[.panes[] | select(.label != null)] | length")" = 4 ]'

# T34 one locked tab does not stop the others
setup p1; P2=$T/p2; mkdir -p "$P2"; unset HERDR_PANE_ID
# shellcheck disable=SC2046
state_multi $(three w1 "$PROJ") $(three w2 "$P2")
echo "DEVLAYOUT_STARTUP=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
mkdir -p "$HERDR_PLUGIN_STATE_DIR/run/$(key_of "$PROJ").lock"
out=$("$DL" startup 2>&1); rc=$?
check "startup locked tab -> that tab skipped, the other repaired" '[ $rc -eq 0 ] && [ -z "$(runs_for w1:p3)" ] && [ -n "$(runs_for w2:p3)" ] && printf %s "$out" | grep -q "in progress"'

# T35 pane whose shell is still starting right after server start -> wait, then type
setup p1; unset HERDR_PANE_ID
# shellcheck disable=SC2046
state_multi $(three w1 "$PROJ")
set_pane w1:p3 fg_starting 2
printf '%s\n' DEVLAYOUT_STARTUP=1 DEVLAYOUT_SHELL_WAIT=3 >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$("$DL" startup 2>&1)
check "startup shell starting -> editor typed after waiting" '[ -n "$(runs_for w1:p3)" ] && ! printf %s "$out" | grep -q skipped'

# ── worktree event hook ──
# Event payload as herdr sends it in HERDR_PLUGIN_EVENT_JSON. $1=event $2=workspace $3=active tab $4=worktree path $5=already_open
evt() {
  jq -cn --arg e "$1" --arg w "$2" --arg t "$3" --arg p "$4" --argjson a "${5:-false}" \
    '{event: $e, data: {type: $e, workspace: {workspace_id: $w, active_tab_id: $t, worktree: {checkout_path: $p}},
      worktree: {path: $p, open_workspace_id: $w}, already_open: $a}}'
}

# T36 off by default -> no output, no change
setup wt; state_panes ""; unset HERDR_PANE_ID
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_created w1 w1:t1 "$PROJ") "$DL" worktree-event 2>&1); rc=$?
check "worktree event off by default -> silent, no change" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(nruns)" = 0 ] && [ "$(q ".panes | length")" = 1 ]'

# T37 on + worktree.created on a 1-pane workspace -> build the layout with a new agent
setup wt; state_panes ""; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_created w1 w1:t1 "$PROJ") "$DL" worktree-event 2>&1); rc=$?
check "worktree created -> layout built" '[ $rc -eq 0 ] && [ "$(q ".panes | length")" = 3 ] && [ "$(q "[.panes[] | .label] | join(\",\")")" = "claude,reviewr,nvim" ]'
check "worktree created -> new agent, editor and review typed" 'runs_for w1:p1 | grep -q "exec claude" && ! runs_for w1:p1 | grep -q continue && [ -n "$(runs_for w1:p2)" ] && [ -n "$(runs_for w1:p3)" ]'
check "worktree created -> socket keyed by the worktree path" 'runs_for w1:p3 | grep -qF "$(key_of "$PROJ").sock"'

# T38 worktree.opened for an already open workspace -> leave it alone
setup wt; state_panes ""; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_opened w1 w1:t1 "$PROJ" true) "$DL" worktree-event 2>&1); rc=$?
check "worktree opened, already_open -> no change" '[ $rc -eq 0 ] && [ "$(nruns)" = 0 ] && [ "$(q ".panes | length")" = 1 ]'

# T39 second event for the same workspace (layout already there) -> no change
setup wt; state_panes "claude,reviewr,nvim"; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_opened w1 w1:t1 "$PROJ") "$DL" worktree-event 2>&1); rc=$?
check "worktree event on a built layout -> no change" '[ $rc -eq 0 ] && [ "$(nruns)" = 0 ] && [ "$(q ".panes | length")" = 3 ]'

# T40 2 panes (e.g. reviewr auto-opened its own) -> no change, hint about auto_open
setup wt; state_panes ",reviewr-own"; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_created w1 w1:t1 "$PROJ") "$DL" worktree-event 2>&1); rc=$?
check "worktree event with 2 panes -> no change, auto_open hint" '[ $rc -eq 0 ] && [ "$(nruns)" = 0 ] && [ "$(q ".panes | length")" = 2 ] && printf %s "$out" | grep -q "auto_open = false"'

# T41 lock held (created and opened run at the same time) -> exit quietly, no change
setup wt; state_panes ""; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
mkdir -p "$HERDR_PLUGIN_STATE_DIR/run/$(key_of "$PROJ").lock"
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_created w1 w1:t1 "$PROJ") "$DL" worktree-event 2>&1); rc=$?
check "worktree event while locked -> quiet exit 0, no change" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(nruns)" = 0 ]'

# T42 no event payload -> exit 0 with a message, nothing guessed from the focused workspace
setup wt; state_panes ""; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(HERDR_PLUGIN_EVENT_JSON='' "$DL" worktree-event 2>&1); rc=$?
check "worktree event without payload -> exit 0, message, no change" '[ $rc -eq 0 ] && [ -n "$out" ] && [ "$(nruns)" = 0 ]'

# T43 active tab missing from the payload -> taken from workspace get
setup wt; state_panes ""; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(HERDR_PLUGIN_EVENT_JSON=$(evt worktree_created w1 "" "$PROJ" | jq -c 'del(.data.workspace.active_tab_id)') "$DL" worktree-event 2>&1); rc=$?
check "worktree event without active_tab_id -> layout built" '[ $rc -eq 0 ] && [ "$(q ".panes | length")" = 3 ]'

# ── notifications for runs without a screen ──
nnotes() { q '(.notifications // []) | length'; }
note() { q "(.notifications // [])[$1] | .$2 // empty"; }

# T44 error -> one notification with the error text (tests capture output, so stderr is not a terminal)
setup proj; state_panes ",x"
out=$("$DL" 2>&1); rc=$?
check "error -> one notification" '[ $rc -ne 0 ] && [ "$(nnotes)" = 1 ] && [ "$(note 0 title)" = "devlayout: error" ] && note 0 body | grep -q "Run reset"'

# T45 DEVLAYOUT_NOTIFY=off -> no notification
setup proj; state_panes ",x"
echo "DEVLAYOUT_NOTIFY=off" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
"$DL" >/dev/null 2>&1
check "NOTIFY=off -> no notification" '[ "$(nnotes)" = 0 ]'

# T46 skipped role -> one notification naming it
setup proj; state_panes "claude,reviewr,nvim"
set_pane w1:p3 fg '"vim"'
"$DL" >/dev/null 2>&1
check "skipped -> one notification" '[ "$(nnotes)" = 1 ] && [ "$(note 0 title)" = "devlayout: skipped" ] && note 0 body | grep -qF "editor(vim)"'

# T47 normal build and "all running" -> no notification
setup proj; state_panes ""
"$DL" >/dev/null 2>&1; "$DL" >/dev/null 2>&1
check "success -> no notification" '[ "$(nnotes)" = 0 ]'

# T48 worktree event that cannot build -> notification
setup wt; state_panes ",reviewr-own"; unset HERDR_PANE_ID
echo "DEVLAYOUT_WORKTREE=1" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
HERDR_PLUGIN_EVENT_JSON=$(evt worktree_created w1 w1:t1 "$PROJ") "$DL" worktree-event >/dev/null 2>&1
check "worktree not built -> notification" '[ "$(nnotes)" = 1 ] && note 0 body | grep -q "auto_open = false"'

# T49 the notification command failing changes nothing else
setup proj; state_panes ",x"
out=$(MOCK_NOTIFY_FAIL=1 "$DL" 2>&1); rc=$?
check "notification fails -> same exit code and message" '[ $rc -eq 1 ] && printf %s "$out" | grep -q "Run reset" && [ "$(nnotes)" = 0 ]'
setup proj; state_panes "claude,reviewr,nvim"
set_pane w1:p3 fg '"vim"'
out=$(MOCK_NOTIFY_FAIL=1 "$DL" 2>&1); rc=$?
check "notification fails on skip -> still exits 0, others typed" '[ $rc -eq 0 ] && [ -n "$(runs_for w1:p2)" ]'

# ── herdr resumes the agent itself right after a server start ──
# herdr types `claude --resume <id>` as soon as the pane is spawned, before the shell is ready. A check
# made in that moment still sees the shell, and whatever devlayout types would land in the resumed Claude.

# T50 agent pane whose shell just started; herdr's agent appears a moment later -> do not type into it
setup proj; state_panes "claude,reviewr,nvim"
echo "DEVLAYOUT_AGENT_SETTLE=2" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
sleep 30 & young=$!
set_pane w1:p1 shell_pid_real "$young"
set_pane w1:p1 fg_later '{"after": 1, "prog": "claude"}'
out=$("$DL" 2>&1); rc=$?
check "young agent shell, agent appears -> nothing typed into agent" '[ $rc -eq 0 ] && [ -z "$(runs_for w1:p1)" ] && printf %s "$out" | grep -qF "agent(claude)"'
check "editor and review still typed" '[ -n "$(runs_for w1:p2)" ] && [ -n "$(runs_for w1:p3)" ]'
stop_bg "$young"

# T51 agent pane with an old shell -> no settling wait, agent typed at once
setup proj; state_panes "claude,reviewr,nvim"
echo "DEVLAYOUT_AGENT_SETTLE=5" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
set_pane w1:p1 shell_pid_real 1
t0=$(date +%s); "$DL" >/dev/null 2>&1; t1=$(date +%s)
check "old agent shell -> typed without waiting" '[ -n "$(runs_for w1:p1)" ] && [ $((t1 - t0)) -lt 4 ]'

# ── open-file run by reviewr, which hands over its terminal ──
# With a terminal attached, `nvim --server … --remote-expr` starts a TUI client (nvim 0.12) and its
# escape codes land in the captured file name. They broke `:drop` and the rest ran as normal-mode keys.
# The fake nvim prints those codes unless it is run with --headless.
fake_nvim() {
  mkdir -p "$T/bin" "$T/sock"
  cat >"$T/bin/nvim" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$NVIM_LOG"
tui=1; for a in "$@"; do [ "$a" = --headless ] && tui=0; done
for a in "$@"; do last=$a; done
case " $* " in
  *" --remote-expr "*)
    [ $tui = 1 ] && printf '\033[?1049h\033[H\033[2J'
    case $last in fnameescape*) printf '%s\n' "$last" | sed "s/^fnameescape('//; s/')\$//" ;; *) echo 1 ;; esac ;;
esac
exit 0
EOF
  chmod +x "$T/bin/nvim"
  echo "DEVLAYOUT_SOCKET_DIR=$T/sock" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$("$DL" editor-socket "$PROJ")"
  export NVIM_LOG="$T/nvim.log"
}

# T52 open-file -> the file name sent to the editor has no terminal escape codes
setup proj; state_panes "claude,reviewr,nvim"; fake_nvim
echo x >"$PROJ/a.txt"
PATH="$T/bin:$PATH" "$DL" open-file "$PROJ/a.txt" 7 >/dev/null 2>&1; rc=$?
sent=$(grep -- '--remote-send' "$NVIM_LOG")
check "open-file sends a clean :drop to the editor" '[ $rc -eq 0 ] && printf %s "$sent" | grep -qF ":drop $PROJ/a.txt<CR>:7<CR>" && ! printf %s "$sent" | grep -q "$(printf "\033")"'
check "every nvim client call is headless" '! grep -v -- --headless "$NVIM_LOG" | grep -q .'

# ── the editor's nvim was quit by mistake ──
nlines() { runs_for "$1" | grep -c . ; }
editor_pid() { printf '%s/run/%s.editor.pid\n' "$HERDR_PLUGIN_STATE_DIR" "$(key_of "$PROJ")"; }

# T53 quit right after start (within the cooldown): the pid file's process is gone -> start it again
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
"$DL" >/dev/null 2>&1
sh -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" >"$(editor_pid)"
out=$("$DL" 2>&1)
check "quit within the cooldown -> editor typed again" '[ "$(nlines w1:p3)" = 2 ] && printf %s "$out" | grep -q "restarted: editor"'
check "quit within the cooldown -> review (still starting) not typed again" '[ "$(nlines w1:p2)" = 1 ]'

# T54 within the cooldown, the program is still running -> nothing typed
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
"$DL" >/dev/null 2>&1
sleep 30 & live=$!
echo "$live" >"$(editor_pid)"
out=$("$DL" 2>&1)
check "within the cooldown, editor alive -> not typed again" '[ "$(nlines w1:p3)" = 1 ]'
stop_bg "$live"

# T55 a stale pid file is removed before typing, so the new start is not judged by it
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
mkdir -p "$HERDR_PLUGIN_STATE_DIR/run"
sh -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" >"$(editor_pid)"
"$DL" >/dev/null 2>&1
out=$("$DL" 2>&1)
check "old pid file -> removed when typing, second press types nothing" '[ "$(nlines w1:p3)" = 1 ] && [ ! -f "$(editor_pid)" ]'

# T56 reviewr e while the editor pane is a shell -> nvim starts in the editor pane with the file
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
rm -f "$("$DL" editor-socket "$PROJ")"
echo x >"$PROJ/a.txt"
out=$(HERDR_PANE_ID=w1:p2 PATH="$T/bin:$PATH" "$DL" open-file "$PROJ/a.txt" 7 2>&1); rc=$?
check "open-file, no editor -> started in the editor pane" '[ $rc -eq 0 ] && runs_for w1:p3 | grep -q "nvim --listen" && runs_for w1:p3 | grep -qF "+7" && runs_for w1:p3 | grep -qF "a.txt"'
check "open-file, no editor -> nvim not run in the reviewr pane" '! grep -qF "+7" "$NVIM_LOG" 2>/dev/null && [ -z "$(runs_for w1:p2)" ]'
check "open-file, no editor -> typed text is valid shell" 'all_runs_parse'

# T57 the editor pane is busy -> open the file right here (in the reviewr pane), type nothing
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
rm -f "$("$DL" editor-socket "$PROJ")"
set_pane w1:p3 fg '"vim"'
echo x >"$PROJ/a.txt"
out=$(HERDR_PANE_ID=w1:p2 PATH="$T/bin:$PATH" "$DL" open-file "$PROJ/a.txt" 7 2>&1); rc=$?
check "open-file, editor pane busy -> nvim here, nothing typed" '[ $rc -eq 0 ] && grep -qF "+7 $PROJ/a.txt" "$NVIM_LOG" && [ "$(nruns)" = 0 ]'

# T58 outside herdr -> open the file right here
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
rm -f "$("$DL" editor-socket "$PROJ")"
echo x >"$PROJ/a.txt"
out=$(env -u HERDR_ENV -u HERDR_PANE_ID PATH="$T/bin:$PATH" "$DL" open-file "$PROJ/a.txt" 7 2>&1); rc=$?
check "open-file outside herdr -> nvim here" '[ $rc -eq 0 ] && grep -qF "+7 $PROJ/a.txt" "$NVIM_LOG" && [ "$(nruns)" = 0 ]'

# T59 a file from another project -> not opened in this tab's editor
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
mkdir -p "$T/other"; echo x >"$T/other/b.txt"
out=$(HERDR_PANE_ID=w1:p2 PATH="$T/bin:$PATH" "$DL" open-file "$T/other/b.txt" 3 2>&1); rc=$?
check "open-file, other project -> nvim here, nothing typed" '[ $rc -eq 0 ] && grep -qF "+3 $T/other/b.txt" "$NVIM_LOG" && [ "$(nruns)" = 0 ]'

# T60 nvim started by hand in the editor pane -> the skip message says how to make it receive files
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
set_pane w1:p3 fg '"nvim"'
out=$("$DL" 2>&1)
check "hand-started nvim in the editor pane -> hint about --listen" 'printf %s "$out" | grep -qF "nvim --listen \"\$(devlayout editor-socket)\""'

# ── state / focus / show / edit (for agent skills and hooks) ──
focus_log() { q '(.focus_log // []) | join(",")'; }
# The user looks at another tab: pane w1:p4 in tab t2 has the focus
look_elsewhere() { set_pane w1:p1 focused false; set_pane w1:p4 focused true; }

# T61 state of a 3-pane layout tab, as JSON
setup proj; state_panes "claude,reviewr,nvim" "claude,,"
set_pane w1:p2 fg '"vim"'
out=$("$DL" state 2>&1); rc=$?
check "state -> valid JSON" '[ $rc -eq 0 ] && printf %s "$out" | jq -e . >/dev/null'
check "state -> layout, viewing, focused role" '[ "$(printf %s "$out" | jq -r "[.layout, .viewing, .focused_role] | map(tostring) | join(\",\")")" = "devlayout,true,agent" ]'
check "state -> role panes" '[ "$(printf %s "$out" | jq -r "[.roles.agent.pane, .roles.editor.pane, .roles.review.pane] | join(\",\")")" = "w1:p1,w1:p3,w1:p2" ]'
check "state -> program states (agent detected, editor stopped, review pane busy)" '[ "$(printf %s "$out" | jq -r "[.roles.agent.state, .roles.editor.state, .roles.review.state] | join(\",\")")" = "running,stopped,busy vim" ]'
check "state -> types nothing" '[ "$(nruns)" = 0 ]'

# T62 state of a one-pane tab
setup proj; state_panes ""
out=$("$DL" state 2>&1)
check "state, 1 pane -> layout single, roles missing" '[ "$(printf %s "$out" | jq -r "[.layout, .roles.editor.state] | join(\",\")")" = "single,missing" ]'

# T63 state when the user looks at another tab
setup proj; state_panes "claude,reviewr,nvim," "" "t1,t1,t1,t2"; look_elsewhere
out=$("$DL" state 2>&1)
check "state, user on another tab -> viewing false" '[ "$(printf %s "$out" | jq -r .viewing)" = false ]'

# T64 focus editor / review
setup proj; state_panes "claude,reviewr,nvim"
out=$("$DL" focus editor 2>&1); rc=$?
check "focus editor -> editor pane focused" '[ $rc -eq 0 ] && [ "$(focus_log)" = "w1:p3" ] && [ "$(q ".panes[] | select(.focused) | .pane_id")" = w1:p3 ]'
out=$("$DL" focus review 2>&1)
check "focus review (from the editor) -> review pane focused" '[ "$(focus_log)" = "w1:p3,w1:p2" ]'
out=$("$DL" focus agent 2>&1)
check "focus agent -> agent pane focused" '[ "$(q ".panes[] | select(.focused) | .pane_id")" = w1:p1 ]'
out=$("$DL" focus agent 2>&1)
check "focus on the focused pane -> nothing to do" '[ "$(focus_log)" = "w1:p3,w1:p2,w1:p1" ]'

# T65 the user looks at another tab -> focus stays, a notification instead
setup proj; state_panes "claude,reviewr,nvim," "" "t1,t1,t1,t2"; look_elsewhere
out=$("$DL" focus agent "Claude has a question" 2>&1); rc=$?
check "focus, user on another tab -> focus unchanged" '[ $rc -eq 0 ] && [ -z "$(focus_log)" ] && [ "$(q ".panes[] | select(.focused) | .pane_id")" = w1:p4 ]'
check "focus, user on another tab -> notification with the message" '[ "$(q ".notifications[0].body")" = "Claude has a question" ]'

# T66 DEVLAYOUT_FOCUS=off -> never move the focus
setup proj; state_panes "claude,reviewr,nvim"
echo DEVLAYOUT_FOCUS=off >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$("$DL" focus editor 2>&1); rc=$?
check "DEVLAYOUT_FOCUS=off -> focus unchanged, notification" '[ $rc -eq 0 ] && [ -z "$(focus_log)" ] && [ "$(nnotes)" = 1 ]'

# T67 focus errors
setup proj; state_panes "claude,reviewr,nvim"
out=$("$DL" focus nope 2>&1); rc=$?
check "focus unknown role -> usage error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "usage: devlayout focus"'
setup proj; state_panes ""
out=$("$DL" focus editor 2>&1); rc=$?
check "focus, no editor pane -> error that says run open" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "run open"'

# T68 show FILE:LINE -> file viewer popup rooted at the project
setup proj; state_panes "claude,reviewr,nvim"
mkdir -p "$PROJ/docs"; echo x >"$PROJ/docs/plan.md"
out=$(cd "$PROJ" && "$DL" show docs/plan.md:30-40 2>&1); rc=$?
opened=$(q '.plugin_opens[0] // [] | join(" ")')
check "show -> popup with the target" '[ $rc -eq 0 ] && printf %s "$opened" | grep -qF -- "--placement popup" && printf %s "$opened" | grep -qF "HERDR_FILE_VIEWER_OPEN=docs/plan.md:30-40"'
check "show -> rooted at the project" 'printf %s "$opened" | grep -qF "HERDR_FILE_VIEWER_ROOT=$(cd "$PROJ" && pwd -P)"'
check "show -> plugin and entrypoint" 'printf %s "$opened" | grep -qF -- "--plugin herdr-file-viewer --entrypoint file-viewer"'

# T69 show: a colon that is not a line number belongs to the file name
setup proj; state_panes "claude,reviewr,nvim"
echo x >"$PROJ/a:b.md"
out=$("$DL" show "$PROJ/a:b.md" 2>&1); rc=$?
check "show a:b.md -> whole name is the file" '[ $rc -eq 0 ] && q ".plugin_opens[0] | join(\" \")" | grep -qF "HERDR_FILE_VIEWER_OPEN=a:b.md"'

# T70 show errors: popup already open, viewer not installed, missing file
setup proj; state_panes "claude,reviewr,nvim"; echo x >"$PROJ/a.md"
out=$(MOCK_PLUGIN_ERR=ui_busy "$DL" show "$PROJ/a.md" 2>&1); rc=$?
check "show, popup already open -> error says close it" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "already open"'
out=$(MOCK_PLUGIN_ERR=plugin_not_found "$DL" show "$PROJ/a.md" 2>&1); rc=$?
check "show, viewer not installed -> install hint" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "herdr plugin install smarzban/herdr-file-viewer"'
out=$("$DL" show "$PROJ/nope.md" 2>&1); rc=$?
check "show, no such file -> error" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "no such file"'

# T71 show while the user looks at another tab -> no popup there, a notification instead
setup proj; state_panes "claude,reviewr,nvim," "" "t1,t1,t1,t2"; look_elsewhere; echo x >"$PROJ/a.md"
out=$("$DL" show "$PROJ/a.md" 2>&1); rc=$?
check "show, user on another tab -> no popup, notification" '[ $rc -eq 0 ] && [ "$(q "(.plugin_opens // []) | length")" = 0 ] && [ "$(nnotes)" = 1 ]'

# T72 edit with a listening editor -> :drop, then focus the editor pane
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
echo x >"$PROJ/a.txt"
out=$(PATH="$T/bin:$PATH" "$DL" edit "$PROJ/a.txt" 12 2>&1); rc=$?
check "edit, editor listening -> :drop and line sent" '[ $rc -eq 0 ] && grep -qF ":drop $(cd "$PROJ" && pwd -P)/a.txt<CR>:12<CR>" "$NVIM_LOG"'
check "edit, editor listening -> editor pane focused" '[ "$(focus_log)" = w1:p3 ]'

# T73 edit with the editor quit -> nvim started in the editor pane with the file, then focus
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
rm -f "$("$DL" editor-socket "$PROJ")"; echo x >"$PROJ/a.txt"
out=$(PATH="$T/bin:$PATH" "$DL" edit "$PROJ/a.txt" 12 2>&1); rc=$?
check "edit, editor quit -> started in the editor pane" '[ $rc -eq 0 ] && runs_for w1:p3 | grep -qF "+12" && [ "$(focus_log)" = w1:p3 ]'
check "edit, editor quit -> typed text is valid shell" 'all_runs_parse'

# T74 edit with the editor pane busy -> error, nothing typed, nvim never started here
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
rm -f "$("$DL" editor-socket "$PROJ")"; echo x >"$PROJ/a.txt"
set_pane w1:p3 fg '"vim"'
out=$(PATH="$T/bin:$PATH" "$DL" edit "$PROJ/a.txt" 12 2>&1); rc=$?
check "edit, editor pane busy -> error, nothing typed or run" '[ $rc -ne 0 ] && [ "$(nruns)" = 0 ] && ! grep -qF "+12" "$NVIM_LOG" 2>/dev/null && [ -z "$(focus_log)" ]'

# T75 edit a file of another project -> error
setup proj; state_panes "claude,reviewr,nvim" "claude,,"; fake_nvim
mkdir -p "$T/other"; echo x >"$T/other/b.txt"
out=$(PATH="$T/bin:$PATH" "$DL" edit "$T/other/b.txt" 2>&1); rc=$?
check "edit, other project -> error, nothing sent" '[ $rc -ne 0 ] && printf %s "$out" | grep -q "not in this tab" && ! grep -q drop "$NVIM_LOG" 2>/dev/null'

# T77 run from a pane shell (no HERDR_PLUGIN_*_DIR): the same settings and state as the plugin action
setup proj; state_panes ""
mkdir -p "$T/home/.config/herdr/plugins/config/merlin00.devlayout"
echo DEVLAYOUT_REVIEW_CMD=my-review >"$T/home/.config/herdr/plugins/config/merlin00.devlayout/config.env"
out=$(env -u HERDR_PLUGIN_STATE_DIR -u HERDR_PLUGIN_CONFIG_DIR -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$T/home" "$DL" open 2>&1); rc=$?
check "shell run -> reads the plugin's config.env" '[ $rc -eq 0 ] && runs_for w1:p2 | grep -q "exec my-review"'
check "shell run -> keeps state in the plugin's state folder" '[ -n "$(ls "$T/home/.local/state/herdr/plugins/merlin00.devlayout/run/" 2>/dev/null)" ]'

# ── hook question (Claude Code plugin hook before AskUserQuestion) ──
# T78 in a layout tab -> the agent pane gets the focus, nothing printed
setup proj; state_panes "claude,reviewr,nvim"; set_pane w1:p1 focused false; set_pane w1:p3 focused true
out=$("$DL" hook question </dev/null 2>&1); rc=$?
check "hook question -> agent pane focused, quiet" '[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(focus_log)" = w1:p1 ]'

# T79 outside herdr -> exit 0, no output, herdr untouched
setup proj; state_panes "claude,reviewr,nvim"; cp "$MOCK_STATE" "$T/before.json"
out=$(env -u HERDR_ENV "$DL" hook question </dev/null 2>&1); rc=$?
check "hook question outside herdr -> quiet no-op" '[ $rc -eq 0 ] && [ -z "$out" ] && cmp -s "$MOCK_STATE" "$T/before.json"'

# T80 a tab without the layout, or the user on another tab -> exit 0, focus unchanged, no error notice
setup proj; state_panes ""
out=$("$DL" hook question </dev/null 2>&1); rc=$?
check "hook question, no layout -> quiet no-op" '[ $rc -eq 0 ] && [ -z "$out" ] && [ -z "$(focus_log)" ] && [ "$(nnotes)" = 0 ]'
setup proj; state_panes "claude,reviewr,nvim," "" "t1,t1,t1,t2"; look_elsewhere
out=$("$DL" hook question </dev/null 2>&1); rc=$?
check "hook question, user on another tab -> focus unchanged, question notice" '[ $rc -eq 0 ] && [ -z "$(focus_log)" ] && [ "$(note 0 body)" = "Claude has a question" ]'

# ── doctor ──
# A complete setup: programs on PATH, key bindings, reviewr editor, file viewer, Claude plugin
doctor_env() {
  mkdir -p "$T/bin" "$T/home/.config/herdr/plugins/config/persiyanov.reviewr"
  for _b in claude nvim herdr-reviewr; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$_b"; chmod +x "$T/bin/$_b"; done
  # fake claude: `claude plugin list --json` prints $CLAUDE_PLUGINS
  printf '#!/bin/sh\n[ "$1 $2 $3" = "plugin list --json" ] && printf "%%s\\n" "${CLAUDE_PLUGINS:-[]}"\nexit 0\n' >"$T/bin/claude"
  ln -s "$DL" "$T/bin/devlayout"
  printf '%s\n' '[[keys.command]]' 'command = "merlin00.devlayout.open"' '[[keys.command]]' 'command = "merlin00.devlayout.reset"' >"$T/home/.config/herdr/config.toml"
  echo 'editor = "devlayout open-file {file} {line}"' >"$T/home/.config/herdr/plugins/config/persiyanov.reviewr/config.toml"
  _tmp=$MOCK_STATE.tmp; jq '.plugins = [{"plugin_id": "herdr-file-viewer"}, {"plugin_id": "merlin00.devlayout"}]' "$MOCK_STATE" >"$_tmp" && mv "$_tmp" "$MOCK_STATE"
  CLAUDE_PLUGINS=$(claude_plugins true); export CLAUDE_PLUGINS
}
# `claude plugin list --json` with the devlayout plugin at this version. $1=enabled (true|false)
claude_plugins() { jq -cn --arg v "$("$DL" version | cut -d' ' -f2)" --argjson e "$1" '[{id: "devlayout@herdr-devlayout", version: $v, enabled: $e}]'; }
doctor() { env -u XDG_CONFIG_HOME HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$DL" doctor 2>&1; }

# T81 everything in place -> exit 0, no missing or warn lines
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(doctor); rc=$?
check "doctor, complete setup -> exit 0" '[ $rc -eq 0 ]'
check "doctor, complete setup -> nothing missing" '! printf %s "$out" | grep -Eq "^ *(missing|warn|optional) "'
check "doctor -> names the herdr version" 'printf %s "$out" | grep -q "herdr 0.9.5"'

# T82 herdr too old -> exit 1 with the fix
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(MOCK_HERDR_VERSION=0.9.4 doctor); rc=$?
check "doctor, herdr 0.9.4 -> exit 1, says herdr update" '[ $rc -eq 1 ] && printf %s "$out" | grep -q "^ *missing .*0.9.4" && printf %s "$out" | grep -q "herdr update"'

# T83 optional parts missing -> exit 0, each with how to add it
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
_tmp=$MOCK_STATE.tmp; jq '.plugins = [{"plugin_id": "merlin00.devlayout"}]' "$MOCK_STATE" >"$_tmp" && mv "$_tmp" "$MOCK_STATE"
out=$(CLAUDE_PLUGINS='[]' doctor); rc=$?
check "doctor, no file viewer -> optional + install command" '[ $rc -eq 0 ] && printf %s "$out" | grep -q "^ *optional .*herdr-file-viewer" && printf %s "$out" | grep -q "herdr plugin install smarzban/herdr-file-viewer"'
check "doctor, no Claude plugin -> optional + install command" 'printf %s "$out" | grep -q "claude plugin install devlayout --marketplace merlin00/herdr-devlayout"'

# T84 Claude plugin of another version, or disabled -> warn
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(CLAUDE_PLUGINS='[{"id": "devlayout@herdr-devlayout", "version": "0.0.1", "enabled": true}]' doctor); rc=$?
check "doctor, Claude plugin version differs -> warn, exit 0" '[ $rc -eq 0 ] && printf %s "$out" | grep -q "^ *warn .*0.0.1"'
out=$(CLAUDE_PLUGINS=$(claude_plugins false) doctor)
check "doctor, Claude plugin disabled -> warn with enable command" 'printf %s "$out" | grep -q "claude plugin enable"'

# T85 missing pieces of the setup -> named with the fix
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
rm "$T/bin/devlayout" "$T/bin/nvim" "$T/home/.config/herdr/config.toml"
out=$(doctor); rc=$?
check "doctor, devlayout not on PATH -> ln -s hint" '[ $rc -eq 0 ] && printf %s "$out" | grep -q "ln -s"'
check "doctor, nvim missing -> named" 'printf %s "$out" | grep -q "^ *warn .*nvim"'
check "doctor, no key bindings -> named" 'printf %s "$out" | grep -q "^ *warn .*key binding"'

# T86 no claude command -> the Claude plugin check is skipped, not an error
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
printf '%s\n' DEVLAYOUT_AGENT_CMD=codex >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/codex"; chmod +x "$T/bin/codex"; rm "$T/bin/claude"
out=$(doctor); rc=$?
check "doctor without claude -> Claude plugin check skipped" '[ $rc -eq 0 ] && printf %s "$out" | grep -q "skip.*claude"'

# T87 outside herdr -> exit 1
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(env -u HERDR_ENV -u XDG_CONFIG_HOME HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$DL" doctor 2>&1); rc=$?
check "doctor outside herdr -> exit 1" '[ $rc -eq 1 ] && printf %s "$out" | grep -q "^ *missing .*inside herdr"'

# T88 the hook focuses the pane of the Claude that asks, not the labelled agent pane
setup proj; state_panes "claude,reviewr,nvim"; set_pane w1:p1 focused false; set_pane w1:p2 focused true
out=$(HERDR_PANE_ID=w1:p3 "$DL" hook question </dev/null 2>&1); rc=$?
check "hook question from a Claude in the editor pane -> that pane focused" '[ $rc -eq 0 ] && [ "$(focus_log)" = w1:p3 ]'

# T89 the plugin hook command never fails or prints, even with a broken config.env
setup proj; state_panes "claude,reviewr,nvim"
printf '%s\n' 'echo broken >&2' 'false' >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
hookcmd=$(jq -r ".hooks.PreToolUse[0].hooks[0].command" "$ROOT/hooks/hooks.json")
out=$(CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$hookcmd" </dev/null 2>&1); rc=$?
check "plugin hook command with a broken config.env -> exit 0, quiet" '[ $rc -eq 0 ] && [ -z "$out" ]'

# T90 doctor: an odd entry in claude plugin list does not hide the installed plugin
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(CLAUDE_PLUGINS="$(printf '%s' "$CLAUDE_PLUGINS" | jq -c '[{id: null}, {version: "1"}] + .')" doctor)
check "doctor, entry without id in claude plugin list -> plugin still ok" 'printf %s "$out" | grep -q "^ *ok .*Claude Code plugin devlayout@"'

# T91 doctor: key bindings must be real (not commented out) and include reset
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
printf '%s\n' '# command = "merlin00.devlayout.open"' '# command = "merlin00.devlayout.reset"' >"$T/home/.config/herdr/config.toml"
out=$(doctor)
check "doctor, commented-out key bindings -> warn" 'printf %s "$out" | grep -q "^ *warn .*key binding"'
printf '%s\n' 'command = "merlin00.devlayout.open"' >"$T/home/.config/herdr/config.toml"
out=$(doctor)
check "doctor, only the open key -> warn names reset" 'printf %s "$out" | grep -q "^ *warn .*merlin00.devlayout.reset"'

# T92 doctor: a prerelease of the minimum version is not enough; a newer minor is
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(MOCK_HERDR_VERSION=0.9.5-rc1 doctor); rc=$?
check "doctor, herdr 0.9.5-rc1 -> missing" '[ $rc -eq 1 ] && printf %s "$out" | grep -q "^ *missing .*0.9.5-rc1"'
out=$(MOCK_HERDR_VERSION=0.10.0 doctor); rc=$?
check "doctor, herdr 0.10.0 -> ok" '[ $rc -eq 0 ] && printf %s "$out" | grep -q "^ *ok .*herdr 0.10.0"'

# T93 doctor: with DEVLAYOUT_EDITOR_CMD the fix names that setting
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
echo "DEVLAYOUT_EDITOR_CMD='hx .'" >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
out=$(doctor)
check "doctor, missing editor from EDITOR_CMD -> names DEVLAYOUT_EDITOR_CMD" 'printf %s "$out" | grep -q "set DEVLAYOUT_EDITOR_CMD"'

# T94 doctor: checks that cannot run say so (skip) instead of vanishing
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
out=$(MOCK_SERVER_DOWN=1 doctor); rc=$?
check "doctor, server down -> exit 1, file viewer check skipped" '[ $rc -eq 1 ] && printf %s "$out" | grep -q "^ *skip .*file viewer"'

# T95 doctor: herdr config folder comes from the plugin config folder when herdr sets it
setup proj; state_panes "claude,reviewr,nvim"; doctor_env
mv "$T/home/.config/herdr" "$T/herdrcfg"
out=$(HERDR_PLUGIN_CONFIG_DIR="$T/herdrcfg/plugins/config/merlin00.devlayout" doctor)
check "doctor, plugin config dir elsewhere -> key bindings and reviewr found there" '! printf %s "$out" | grep -Eq "^ *(warn|optional) .*(key binding|reviewr)"'

# T96 bin/devlayout sticks to its allowed tools (no grep)
check "bin/devlayout does not call grep" '! awk "/^[[:space:]]*#/ { next } /(^|[^a-z_-])grep /" "$DL" | grep -q .'

# ── Claude Code plugin files ──
check "Claude plugin manifests are valid JSON" 'jq -e . "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json" "$ROOT/hooks/hooks.json" >/dev/null'
check "Claude plugin version = devlayout version = herdr-plugin.toml version" '_v=$("$DL" version | cut -d" " -f2); [ "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" = "$_v" ] && [ "$(jq -r ".plugins[0].version" "$ROOT/.claude-plugin/marketplace.json")" = "$_v" ] && grep -q "^version = \"$_v\"" "$ROOT/herdr-plugin.toml"'
check "doctor minimum herdr = min_herdr_version" 'grep -q "^min_herdr_version = \"$(sed -n "s/^MIN_HERDR=\([0-9.]*\).*/\1/p" "$DL")\"" "$ROOT/herdr-plugin.toml"'
check "plugin hook runs devlayout hook question" 'jq -r ".hooks.PreToolUse[0].hooks[0].command" "$ROOT/hooks/hooks.json" | grep -qF "bin/devlayout\" hook question"'

echo
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
