#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Perf gate: stable's Release lab against this branch's, interleaved, on the bench loops the change touches.
# Fails when a loop's median main-thread busy per step grows past stable's by more than its A/A noise.
#   tools/bench-gate.sh [auto|<loop,loop,...>] [reps]   auto (default) asks tools/test-impact.py select --perf
#   tools/bench-gate.sh --aa [reps]                     stable against itself on every loop, to measure the noise
# Run directly: it takes heavy-job slots itself. BASE=<ref> replaces stable; its bundle is cached per sha in ~/.cache/artemis/bench-stable.
set -u
setopt extendedglob
cd "$(dirname "$0")/.."
all=(tab tab2 space sidebar bar newtab load idle)
# fraction of stable's median: largest single-run distance from the pooled median, rounded up, at least 2%
# (BASE=37d6a4af tools/bench-gate.sh --aa 4)
typeset -A noise=(tab 0.08 tab2 0.02 space 0.02 sidebar 0.09 bar 0.02 newtab 0.03 load 0.02 idle 0.03)
aa=0; [[ ${1-} == --aa ]] && { aa=1; shift; set -- all "$@"; }
want=${1:-auto} reps=${2:-3}
if (( aa )); then loops=($all)
elif [[ $want == auto ]]; then loops=(${(s:,:)$(tools/test-impact.py select --perf)})
else loops=(${(s:,:)want}); fi
[[ $loops == none || -z $loops ]] && { echo "bench-gate: no bench loop reaches this change"; exit 0; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
sha=$(git rev-parse ${BASE:-stable})
root=~/.cache/artemis/bench-stable cache=$root/$sha
a="$cache/Artemis BenchA.app"
if [[ ! -d $a ]]; then
	tmp=/private/tmp/artemis-bench-stable-$sha-$$ stage=$root/.$sha-$$
	git worktree add --detach $tmp $sha >/dev/null 2>&1 || exit 2
	heavy-job "bench-gate: stable Release ${sha:0:8}" env PERF_ID=BenchA zsh -c "cd $tmp && tools/perflab.sh" >/dev/null \
		|| { git worktree remove --force $tmp; echo "STABLE BUILD FAILED"; exit 1; }
	mkdir -p $stage && mv "$tmp/.build/BenchA/Artemis BenchA.app" $stage/
	# rename(2) fails onto a base another gate already placed, and ours is dropped
	python3 -c 'import os, sys; os.rename(*sys.argv[1:])' $stage $cache 2>/dev/null || rm -rf $stage
	git worktree remove --force $tmp
fi
# a gate touches its base on start; other bases no gate has touched for a day go
touch $cache
find $root -mindepth 1 -maxdepth 1 -type d ! -name $sha -mmin +1440 -exec rm -rf {} +
b=$a
if (( ! aa )); then
	heavy-job "bench-gate: branch Release" env PERF_ID=BenchB tools/perflab.sh >/dev/null || { echo "BUILD FAILED"; exit 1; }
	b="${PWD:A}/.build/BenchB/Artemis BenchB.app"
fi
out=/private/tmp/artemis-perf
mkdir -p $out
# one 60 s loop: launch, wait for the bench to quit, print main busy per step in ms
arm='app=$1 loop=$2 label=$3 out=$4
	exe="$app/Contents/MacOS/${${app:t}%.app}"
	rm -f $out/artemis-bench-$label.log
	open -n --env ARTEMIS_DIAG=perf --env ARTEMIS_BENCH_DIR=$out --env ARTEMIS_BENCH=1 \
		--env ARTEMIS_BENCH_LOOP=$loop --env ARTEMIS_BENCH_LABEL=$label $app
	SECONDS=0 seen=0
	while (( SECONDS < 240 )); do
		if pgrep -qf "^$exe"; then seen=1; elif (( seen || SECONDS > 30 )); then break; fi
		sleep 1
	done
	pkill -f "^$exe"
	sed -n "s/^main busy per step ms: \([0-9.]*\).*/\1/p" $out/artemis-bench-$label.log
	rm -f $out/artemis-bench-$label.log'
# the labs' data goes only under the arms' screen lock, so never under another gate's running arm;
# at the start too, so a gate never inherits a half-wiped state
wipe() { until lockf -t 0 ~/.cache/artemis/foreground.lock zsh -c '
	for bid in BenchA BenchB; do
		defaults delete dev.findles.Artemis.$bid 2>/dev/null
		rm -rf ~/Library/{WebKit,Caches,HTTPStorages,"Application Support"}/dev.findles.Artemis.$bid \
			~/Library/Preferences/dev.findles.Artemis.$bid.plist ~/Library/"Saved Application State"/dev.findles.Artemis.$bid.savedState
	done'; (( $? != 75 )); do sleep 5; done; }
wipe
# a ticket per 3 reps keeps each foreground block short; a busy screen (lockf 75) hands the slots back and retries
results=$(for loop in $loops; do for first in $(seq 1 3 $reps); do
	last=$(( first + 2 < reps ? first + 2 : reps ))
	until heavy-job --both "bench-gate: $loop $first-$last of $reps" lockf -t 0 ~/.cache/artemis/foreground.lock zsh -c '
		arm=$1 a=$2 b=$3 out=$4 first=$5 last=$6 loop=$7
		# 1-min load at launch, after waiting up to 5 min for it to fall under 8
		calm() { for t in {1..10}; do l=$(sysctl -n vm.loadavg | cut -d" " -f2); (( l < 8 )) && break; sleep 30; done; echo $l; }
		for i in $(seq $first $last); do
			for k in $( (( i % 2 )) && echo A B || echo B A ); do
				app=$a; [[ $k == B ]] && app=$b
				echo "$loop $k $(calm) $(zsh -c $arm _ $app $loop gate-$k-$loop-$i $out)"
			done
		done' _ $arm $a $b $out $first $last $loop; (( $? != 75 )); do sleep 60; done
done; done)
print -r -- $results > $out/bench-gate-runs.txt
rm -rf .build/BenchB
wipe
print -r -- $results | python3 -c '
import random, sys, statistics as st
aa, noise = sys.argv[1] == "1", dict(kv.split("=") for kv in sys.argv[2:])
runs, hot = {}, {}
for line in sys.stdin:
    loop, arm, load, *v = line.split()
    r = runs.setdefault(loop, {"A": [], "B": []})
    if float(load) >= 8:
        hot[loop] = hot.get(loop, 0) + 1
    elif v:
        r[arm].append(float(v[0]))
for loop, n in hot.items():
    print(f"{loop:8} {n} run(s) dropped: launched at 1-min load 8 or more")
bad = 0
for loop, r in runs.items():
    if not r["A"] or not r["B"]:
        print(f"{loop:8} NO RESULT  A", r["A"], " B", r["B"]); bad = 1; continue
    a, b = st.median(r["A"]), st.median(r["B"])
    if aa:
        pool = st.median(r["A"] + r["B"])
        spread = max(abs(x / pool - 1) for x in r["A"] + r["B"])
        print(f"{loop:8} A/A median {pool:.2f} ms  ratio {b / a:.3f}  largest run off median {spread:.1%} ({spread * pool:.2f} ms)")
        continue
    limit = float(noise.get(loop, "0.10"))
    verdict = "FAIL" if b > a * (1 + limit) else "ok"
    bad |= verdict == "FAIL"
    # two-sided permutation test on the difference of medians
    pool, n, rng = r["A"] + r["B"], len(r["A"]), random.Random(0)
    shuffles = [rng.sample(pool, len(pool)) for _ in range(20000)]
    p = sum(abs(st.median(s[n:]) - st.median(s[:n])) >= abs(b - a) - 1e-9 for s in shuffles) / len(shuffles)
    print(f"{verdict:4} {loop:8} base {a:.2f} → branch {b:.2f} ms/step ({b / a - 1:+.1%}, noise ±{limit:.0%}, "
          f"p {p:.3f}, runs {n}+{len(pool) - n})")
sys.exit(bad)
' $aa ${(@)${(@k)noise}/(#m)*/$MATCH=$noise[$MATCH]}
