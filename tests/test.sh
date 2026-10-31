#!/bin/bash
# shellcheck disable=SC2015,SC2016  # "a && ok || bad" is intended; expect code is single-quoted on purpose
#
# Tests for vidoas. Needs root, doas (OpenDoas), expect and flock.
# Never touches /etc/doas.conf: every test uses -f with a file in a temp dir.
#
#   sudo ./tests/test.sh [path/to/vidoas]
#
set -u

VIDOAS="$(readlink -f "${1:-$(dirname "$0")/../vidoas}")"
work="$(mktemp -d)" || { echo "cannot create temporary directory" >&2; exit 2; }
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $*"; }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
for t in doas expect flock; do
	command -v "$t" > /dev/null || { echo "missing: $t"; exit 2; }
done

# Fake editor: writes the content of the next file from $work/rounds.N into
# the edited file (round counter in $work/round). Exits with $FAKE_RC if set.
cat > "$work/fake-editor" <<'EOF'
#!/bin/bash
dir="$(dirname "$0")"
n=$(( $(cat "$dir/round" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$dir/round"
echo "$*" > "$dir/args"
file="${!#}"
[ -f "$dir/rounds.$n" ] && cat "$dir/rounds.$n" > "$file"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$work/fake-editor"
export EDITOR="$work/fake-editor"
unset DOAS_EDITOR

VALID=$'permit persist :wheel\n'
VALID2=$'permit nopass root\npermit :wheel\n'
INVALID=$'permit persist :wheel\nthis is not valid\n'

setup() {   # setup <initial content or "-" for missing file>
	rm -rf "${work:?}/etc" "${work:?}"/rounds.* "$work/round" "$work/args"
	mkdir -p "$work/etc"
	conf="$work/etc/doas.conf"
	if [ "$1" != "-" ]; then
		printf '%s' "$1" > "$conf"
		chmod 0400 "$conf"
	fi
}
rounds() {  # rounds <content1> [<content2> ...]
	local i=1
	for c in "$@"; do printf '%s' "$c" > "$work/rounds.$i"; i=$((i + 1)); done
}
# exp <expect commands>: spawn "vidoas -f $conf" under a pty, run the given
# expect commands (use "fail" on timeout/eof), wait for the end and return the
# exit code of vidoas. Timeouts kill vidoas and return 99.
exp() {
	VIDOAS="$VIDOAS" CONF="$conf" expect -c '
		set timeout 10
		proc fail {} { catch {exec kill [exp_pid]}; catch wait; exit 99 }
		spawn $env(VIDOAS) -f $env(CONF)
		'"$1"'
		expect eof {} timeout fail
		catch wait r
		exit [lindex $r 3]
	'
}
wait_for() { # wait_for <pattern>
	printf 'expect "%s" {} timeout fail eof fail\n' "$1"
}
step() { # step <pattern> <answer>
	printf 'expect "%s" { send "%s\r" } timeout fail eof fail\n' "$1" "$2"
}
leftovers() { find "$work/etc" -name 'doas.conf.*' | grep -q .; }

# 1: valid change is saved with root:root 0400
setup "$VALID"; rounds "$VALID2"
out="$("$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$conf")" = "${VALID2%$'\n'}" ] && [ "$(stat -c '%a %u %g' "$conf")" = "400 0 0" ] && ! leftovers; then
	ok "valid change saved, 0400 root:root"
else bad "valid change (rc=$rc, out=$out, mode=$(stat -c '%a %u %g' "$conf"))"; fi

# 2: no change -> unchanged, same inode
setup "$VALID"
ino="$(stat -c %i "$conf")"
out="$("$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [[ $out == *unchanged* ]] && [ "$(stat -c %i "$conf")" = "$ino" ] && ! leftovers; then
	ok "no change -> unchanged, file untouched"
else bad "no change (rc=$rc, out=$out)"; fi

# 3: invalid, then (e)dit again with a fix -> saved
setup "$VALID"; rounds "$INVALID" "$VALID2"
exp "$(step "What now?" e)" > "$work/log" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$conf")" = "${VALID2%$'\n'}" ] && [ "$(cat "$work/round")" = 2 ] && ! leftovers; then
	ok "syntax error -> e -> fixed -> saved"
else bad "error/edit-again (rc=$rc): $(cat "$work/log")"; fi

# 4: invalid, then e(x)it -> unchanged, exit 1, no colors when NO_COLOR is set
setup "$VALID"; rounds "$INVALID"
NO_COLOR=1 exp "$(step "What now?" x)" > "$work/log" 2>&1; rc=$?
if [ $rc -eq 1 ] && [ "$(cat "$conf")" = "${VALID%$'\n'}" ] && grep -q unchanged "$work/log" && ! grep -q $'\033' "$work/log" && ! leftovers; then
	ok "syntax error -> x -> unchanged, exit 1, NO_COLOR honored"
else bad "error/exit (rc=$rc): $(cat "$work/log")"; fi

# 5: the doas error is shown once, our line is red on a terminal
setup "$VALID"; rounds "$INVALID"
exp "$(step "What now?" x)" > "$work/log" 2>&1; rc=$?
if [ $rc -eq 1 ] && [ "$(grep -c 'syntax error' "$work/log")" = 1 ] && grep -q $'\033\[1;31mvidoas: .* not saved' "$work/log"; then
	ok "doas message once, vidoas line red"
else bad "message format: $(cat -v "$work/log")"; fi

# 6: unknown answer repeats the prompt, Enter means edit again
setup "$VALID"; rounds "$INVALID" "$VALID2"
exp "$(step "What now?" foo; wait_for "Options are"; step "What now?" "")" > "$work/log" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$conf")" = "${VALID2%$'\n'}" ]; then
	ok "unknown answer re-prompts, Enter = edit again"
else bad "re-prompt (rc=$rc): $(cat "$work/log")"; fi

# 7: invalid without a terminal -> exit 1 without looping
setup "$VALID"; rounds "$INVALID"
out="$(timeout 10 "$VIDOAS" -f "$conf" < /dev/null 2>&1)"; rc=$?
if [ $rc -eq 1 ] && [ "$(cat "$conf")" = "${VALID%$'\n'}" ] && ! leftovers; then
	ok "syntax error without tty -> exit 1, unchanged"
else bad "no tty (rc=$rc, out=$out)"; fi

# 8: editor with arguments
setup "$VALID"; rounds "$VALID2"
out="$(EDITOR="$work/fake-editor --wait" "$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [[ "$(cat "$work/args")" == "--wait $work/etc/doas.conf."* ]] && [ "$(cat "$conf")" = "${VALID2%$'\n'}" ]; then
	ok "editor with arguments"
else bad "editor args (rc=$rc, out=$out, args=$(cat "$work/args" 2>/dev/null))"; fi

# 9: DOAS_EDITOR wins over EDITOR
setup "$VALID"; rounds "$VALID2"
out="$(DOAS_EDITOR="$work/fake-editor" EDITOR=/nonexistent "$VIDOAS" -f "$conf" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "DOAS_EDITOR preferred" || bad "DOAS_EDITOR (rc=$rc, out=$out)"

# 10: invalid editor command
setup "$VALID"
out="$(EDITOR=/nonexistent/editor "$VIDOAS" -f "$conf" 2>&1)"; rc=$?
[ $rc -eq 1 ] && [[ $out == *"no valid editor"* ]] && ok "invalid editor rejected" || bad "invalid editor (rc=$rc, out=$out)"

# 11: editor fails -> unchanged
setup "$VALID"; rounds "$VALID2"
out="$(FAKE_RC=1 "$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 1 ] && [ "$(cat "$conf")" = "${VALID%$'\n'}" ] && ! leftovers; then
	ok "editor failure -> unchanged"
else bad "editor failure (rc=$rc, out=$out)"; fi

# 12: missing file + content -> created 0400
setup "-"; rounds "$VALID"
out="$("$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ -f "$conf" ] && [ "$(stat -c %a "$conf")" = 400 ]; then
	ok "missing file is created"
else bad "missing file (rc=$rc, out=$out)"; fi

# 13: missing file + nothing written -> still missing
setup "-"
out="$("$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ ! -e "$conf" ] && ! leftovers; then
	ok "missing file + no input -> nothing created"
else bad "missing file empty (rc=$rc, out=$out)"; fi

# 14: lock: second instance is refused (this shell holds the directory lock)
setup "$VALID"; rounds "$VALID2"
exec 8< "$work/etc"
flock -n 8 || bad "could not take the test lock"
out="$("$VIDOAS" -f "$conf" 8<&- 2>&1)"; rc=$?
exec 8<&-
if [ $rc -eq 1 ] && [[ $out == *busy* ]] && [ "$(cat "$conf")" = "${VALID%$'\n'}" ]; then
	ok "locked file -> busy"
else bad "lock (rc=$rc, out=$out)"; fi

# 15: symlink: target is edited, link stays a link
setup "$VALID"; rounds "$VALID2"
mv "$conf" "$work/etc/real.conf"; ln -s real.conf "$conf"
out="$("$VIDOAS" -f "$conf" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ -L "$conf" ] && [ "$(cat "$work/etc/real.conf")" = "${VALID2%$'\n'}" ]; then
	ok "symlink target edited, link kept"
else bad "symlink (rc=$rc, out=$out)"; fi

# 16-18: -c
setup "$VALID"
out="$("$VIDOAS" -c -f "$conf" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [[ $out == *"parsed OK"* ]] && ok "-c on valid file" || bad "-c valid (rc=$rc, out=$out)"
setup "$INVALID"
out="$("$VIDOAS" -c -f "$conf" 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "-c on invalid file" || bad "-c invalid (rc=$rc, out=$out)"
setup "$VALID"; chmod 0666 "$conf"
out="$("$VIDOAS" -c -f "$conf" 2>&1)"; rc=$?
[ $rc -eq 1 ] && [[ $out == *"bad permissions"* ]] && ok "-c on world-writable file" || bad "-c perms (rc=$rc, out=$out)"

# 19: --file= form and -f without argument
setup "$VALID"
out="$("$VIDOAS" -c --file="$conf" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "--file=FILE" || bad "--file= (rc=$rc, out=$out)"
out="$("$VIDOAS" -f 2>&1)"; rc=$?
[ $rc -eq 1 ] && [[ $out == *"requires a file"* ]] && ok "-f without argument" || bad "-f no arg (rc=$rc, out=$out)"

# 20: non-root is refused (-cq: silently, exit status only)
if id nobody > /dev/null 2>&1 && command -v setpriv > /dev/null; then
	nobody=(setpriv --reuid="$(id -u nobody)" --regid="$(id -g nobody)" --clear-groups)
	out="$("${nobody[@]}" "$VIDOAS" -f "$conf" 2>&1)"; rc=$?
	[ $rc -eq 1 ] && [[ $out == *"need to be root"* ]] && ok "non-root refused" || bad "non-root (rc=$rc, out=$out)"
	"${nobody[@]}" "$VIDOAS" -cq "$conf" > "$work/out" 2>&1; rc=$?
	[ $rc -eq 1 ] && [ ! -s "$work/out" ] && ok "non-root -cq: silent, 1" || bad "non-root -cq (rc=$rc, out=$(cat "$work/out"))"
fi

# 21-23: -cq like visudo: no output, only the exit status
setup "$VALID"
"$VIDOAS" -cq -f "$conf" > "$work/out" 2>&1; rc=$?; out="$(cat "$work/out")"
[ $rc -eq 0 ] && [ ! -s "$work/out" ] && ok "-cq on valid file: silent, 0" || bad "-cq valid (rc=$rc, out=$out)"
setup "$INVALID"
"$VIDOAS" -cq -f "$conf" > "$work/out" 2>&1; rc=$?; out="$(cat "$work/out")"
[ $rc -eq 1 ] && [ ! -s "$work/out" ] && ok "-cq on invalid file: silent, 1" || bad "-cq invalid (rc=$rc, out=$out)"
setup "$VALID"; chmod 0666 "$conf"
"$VIDOAS" -cq -f "$conf" > "$work/out" 2>&1; rc=$?; out="$(cat "$work/out")"
[ $rc -eq 1 ] && [ ! -s "$work/out" ] && ok "-cq on world-writable file: silent, 1" || bad "-cq perms (rc=$rc, out=$out)"

# 24: combined -csf FILE, -ffile, -- FILE and a positional file (visudo style)
setup "$VALID"
r1=0; r2=0; r3=0; r4=0
"$VIDOAS" -csf "$conf" > /dev/null 2>&1 || r1=$?
"$VIDOAS" -c "-f$conf" > /dev/null 2>&1 || r2=$?
"$VIDOAS" -c -- "$conf" > /dev/null 2>&1 || r3=$?
"$VIDOAS" -c "$conf" > /dev/null 2>&1 || r4=$?
[ "$r1$r2$r3$r4" = 0000 ] && ok "-csf FILE, -fFILE, -- FILE, positional FILE" || bad "option forms ($r1 $r2 $r3 $r4)"

# 25: file name starting with a dash after -f is not split into options
setup "$VALID"; cp "$conf" "$work/etc/-name"
out="$(cd "$work/etc" && "$VIDOAS" -c -f -name 2>&1)"; rc=$?
[ $rc -eq 0 ] && [[ $out == *"/-name: parsed OK"* ]] && ok "-f -name is a file name" || bad "-f -name (rc=$rc, out=$out)"

# 26: two files are refused
setup "$VALID"
out="$("$VIDOAS" -c -f "$conf" "$conf" 2>&1)"; rc=$?
[ $rc -eq 1 ] && [[ $out == *"only one file"* ]] && ok "two files refused" || bad "two files (rc=$rc, out=$out)"

# 27: -q while editing: saved without messages
setup "$VALID"; rounds "$VALID2"
"$VIDOAS" -q "$conf" > "$work/out" 2>&1; rc=$?; out="$(cat "$work/out")"
[ $rc -eq 0 ] && [ ! -s "$work/out" ] && [ "$(cat "$conf")" = "${VALID2%$'\n'}" ] && ok "-q edit: saved silently" || bad "-q edit (rc=$rc, out=$out)"

# 28: called through a visudo symlink (vidoas-visudo package)
setup "$VALID"; ln -s "$VIDOAS" "$work/visudo"
"$work/visudo" -cq "$conf" > "$work/out" 2>&1; rc=$?; out="$(cat "$work/out")"
[ $rc -eq 0 ] && [ ! -s "$work/out" ] && ok "visudo -cq via symlink" || bad "visudo symlink (rc=$rc, out=$out)"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
