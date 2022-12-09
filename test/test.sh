#!/bin/bash

set -ex

repo=$(git rev-parse --show-toplevel)
d=$(mktemp -d)
trap "rm -rf $d" 0 1 2 3
pushd $d
mkdir local remote bundle

pushd local
git init l1
git init l2
git init l3

pushd l1
echo aaaa >a
git add a
git commit -m "init l1"

git checkout master
git checkout -b br-a
echo cccc >c
git add c
git commit -m "commit br-a"

git checkout master
git checkout -b br-b
echo dddd >d
git add d
git commit -m "commit br-b"
popd

pushd l2
echo bbbb >b
git add b
git commit -m "init l2"

git checkout master
git checkout -b br-b
echo dddd >d
git add d
git commit -m "commit br-b"

git checkout master
git checkout -b br-c
echo xxxx >x
git add x
git commit -m "commit br-c"
popd
popd

pushd remote
git clone $d/local/l1
git clone $d/local/l2
git clone $d/local/l3

pushd l3
echo 1111 >1
git add 1
git commit -m "init l3"
l3_master=$(git rev-parse HEAD)
popd

pushd l2
git checkout br-b
echo 4444 >4
git add 4
git commit -m "add 4"
l2_br_b=$(git rev-parse HEAD)
popd

pushd l1
git checkout br-a
echo mmmm >m
git add m
git commit -m "add m"
l1_br_a=$(git rev-parse HEAD)
popd
popd

pushd local
# history conflict
pushd l2
git checkout br-b
echo 5555 >5
git add 5
git commit -m "add 5"
l2_br_b_at=$(git rev-parse HEAD)
popd

pushd l1
git checkout br-b
echo 1111 >z
git add z
git commit -m "add z"
l1_br_b=$(git rev-parse HEAD)
popd
popd

# run
pushd local
$repo/make-bundle.sh list -l $d/bundle/list.lst l1 l2 l3
popd

cat $d/bundle/list.lst

pushd remote
$repo/make-bundle.sh create -l $d/bundle/list.lst -d $d/bundle l1 l2 l3
popd
ls -l $d/bundle
cat $d/bundle/list.lst

pushd local
$repo/make-bundle.sh unbundle -l $d/bundle/list.lst -d $d/bundle l1 l2 l3
popd

pushd local
for dd in l1 l2 l3; do
    pushd $dd
    git for-each-ref refs/heads
    popd
done

[[ $l1_br_a == $(cd l1 && git rev-parse br-a) ]] || exit 1
[[ $l1_br_b == $(cd l1 && git rev-parse br-b) ]] || exit 1
[[ $l2_br_b == $(cd l2 && git rev-parse br-b) ]] || exit 1
[[ $l2_br_b_at == $(cd l2 && git rev-parse br-b@) ]] || exit 1
[[ $l3_master == $(cd l3 && git rev-parse master) ]] || exit 1
popd

popd >/dev/null
