#!/bin/bash

set -e

function die {
    echo "(EE) $@" >&2
    exit 1
}

function warn {
    echo "(!!) $@" >&2
}

function info {
    echo "(**) $@" >&2
}

if [[ $1 == "-h" || $# -eq 0 ]]; then
    cat >&2 <<EOF
Usage: $0 [-r remote] DIRS...

Run git push on each working-copies on DIRS and replace current
branch to the remote one. And if conflict to local branch (not ff),
the local branch is left with adding '@' on tail.

If you are using public-key authentification for ssh connections,
this script invokes ssh-agent and you can skip inputting the passphrase
every time.
EOF
    exit 1
fi

if [[ $1 == "-r" ]]; then
    shift
    remote=$1
    shift
else
    remote=origin
fi

if [[ -z "$SSH_AGENT_PID" ]]; then
    eval $(ssh-agent)
    trap "kill -TERM $SSH_AGENT_PID" 0 1 2
fi

if [[ ! -z "$SSH_AGENT_PID" ]]; then
    ssh-add || :
fi

function update-repo {
    local dir=$1
    pushd $dir >/dev/null
    info "Processing directory $dir..."
    git push $remote --all
    git push $remote --tags
    popd >/dev/null
}

while [[ ! -z "$1" ]]; do
    update-repo "$1"
    shift
done
