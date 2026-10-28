#!/usr/bin/env bash
# usage: cmprev.sh REV PROG ; builds PROG at engine REV with both compilers
set -e
rev=$1; prog=$2
OLD=/tmp/virgil-cmp/old/bin; NEW=$HOME/research/virgil-titzer/bin
for c in old new; do
  d=/tmp/virgil-cmp/r-$rev-$prog-$c; rm -rf $d; mkdir -p $d
  git -C $HOME/research/wizard-engine-PRs archive $rev | tar -x -C $d
  sed -i 's/local build_time=\$(date "+%Y-%m-%d %H:%M:%S")/local build_time="2026-01-01 00:00:00"/; s/REVS="\$(git rev-list --count HEAD)"/REVS=1/' $d/build.sh
  mkdir -p $d/bin
done
(cd /tmp/virgil-cmp/r-$rev-$prog-old && PATH=$OLD:$PATH USER=x HOST=x ./build.sh $prog x86-64-linux > build.log 2>&1) &
(cd /tmp/virgil-cmp/r-$rev-$prog-new && PATH=$NEW:$PATH USER=x HOST=x ./build.sh $prog x86-64-linux > build.log 2>&1) &
wait
