#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# Regenerate tools/test-impact-map.json: a Debug coverage lab runs the whole self-test, slicing its
# counters per group, then each bench loop, then test-impact.py turns the slices into the map.
# Usage: tools/test-impact-map.sh [LAB_ID]   (run directly: it takes heavy-job slots and the self-test lock itself)
# KEEP=1 keeps the slices and the self-test log in /private/tmp/artemis-coverage-<LAB_ID>
set -u
cd "$(dirname "$0")/.."
id=${1:-Cov}
loops=(tab tab2 space sidebar bar newtab load idle)
app=".build/$id/Artemis $id.app"
exe="${PWD:A}/$app/Contents/MacOS/Artemis $id"
out=/private/tmp/artemis-coverage-$id
log=~/Library/Logs/Artemis/artemis-selftest-$id.log
sha=$(git rev-parse HEAD)
[[ -z $(git status --porcelain -- Artemis Vendor) ]] || { echo "commit first: the map records HEAD's lines"; exit 2; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
heavy-job "test-scope: coverage build $id" env PERF_ID=$id PERF_CONFIG=Debug PERF_COVERAGE=1 tools/perflab.sh >/dev/null || { echo "BUILD FAILED"; exit 1; }
rm -rf $out && mkdir -p $out/suite

# waits for the app to quit, or for the self-test's done line; the 2400 s leave out what $3's pause lines total.
# a paused suite leaves $4; moving it away holds the pause while the slots are lent
wait_app='exe=$1 log=$2; seen=0 SECONDS=0
	while (( SECONDS < 2400 )) || (( SECONDS - $(fin-away --paused ${3:-$log}) < 2400 )); do
		[[ -e $4 ]] && ! fin-away && mv $4 $4.lent 2>/dev/null && { heavy-job --lend fin-away --wait; mv $4.lent $4; }
		[[ -n $log ]] && grep -q "^done" $log 2>/dev/null && { sleep 3; pkill -f "^$exe"; break; }
		if pgrep -qf "^$exe"; then seen=1; elif (( seen || SECONDS > 60 )); then break; fi
		sleep 2
	done'
fg=tools/.perflab-fg-$id.sh
sed 's/open -g -n/open -n/' tools/perflab.sh > $fg
screen=~/.cache/artemis/foreground.lock
suite='id=$1 fg=$2 out=$3 log=$4 exe=$5 wait_app=$6
	fin-away || exit 75
	rm -f $log
	PERF_ID=$id zsh $fg --run ARTEMIS_SELFTEST=1 ARTEMIS_PAUSE_FILE=$out/paused ARTEMIS_COVERAGE_DIR=$out/suite LLVM_PROFILE_FILE=$out/exit-%p.profraw
	zsh -c $wait_app _ $exe $log $log $out/paused'
bench='id=$1 fg=$2 out=$3 exe=$4 wait_app=$5; shift 5
	for loop; do
		heavy-job --lend fin-away --wait
		mkdir -p $out/$loop
		PERF_ID=$id zsh $fg --run ARTEMIS_BENCH=1 ARTEMIS_BENCH_LOOP=$loop ARTEMIS_BENCH_LABEL=coverage-$id-$loop \
			ARTEMIS_COVERAGE_DIR=$out/$loop LLVM_PROFILE_FILE=$out/exit-%p.profraw
		zsh -c $wait_app _ $exe "" /private/tmp/artemis-perf/artemis-bench-coverage-$id-$loop.log
		mv $out/$loop/loop-$loop.profraw $out/suite/
	done'
# the suite, then the loops, each a ticket that takes the screen (and the self-test lock) only if free
# and Fin is away: a 75 hands the slots back and retries
until fin-away --wait; heavy-job --both "lab $id: self-test coverage" lockf -t 0 $screen lockf -t 0 -k ~/.cache/artemis-ce-selftest.lock \
	zsh -c $suite _ $id $fg $out $log $exe $wait_app; (( $? != 75 )); do sleep 60; done
until fin-away --wait; heavy-job --both "lab $id: bench loop coverage" lockf -t 0 $screen \
	zsh -c $bench _ $id $fg $out $exe $wait_app $loops; (( $? != 75 )); do sleep 60; done
rm -f $fg
grep -E '^FAIL|passed, ' $log
dylib=("$app"/Contents/MacOS/*.debug.dylib(N))
python3 tools/test-impact.py build-map $out/suite "${dylib[1]:-$exe}" $sha
[[ -n ${KEEP-} ]] && { cp $log $out/; log=; out=; }
bid=dev.findles.Artemis.$id
defaults delete $bid 2>/dev/null
rm -rf ${out:-/nonexistent} .build/$id ${log:-/nonexistent} ~/Library/Logs/Artemis/*-$id.*(N) /private/tmp/artemis-perf/artemis-bench-coverage-$id-*(N) \
	~/Library/{WebKit,Caches,HTTPStorages,"Application Support"}/$bid ~/Library/Preferences/$bid.plist ~/Library/"Saved Application State"/$bid.savedState
