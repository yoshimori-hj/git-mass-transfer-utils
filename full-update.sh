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

Run git pull on each working-copies on DIRS and replace current
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

if [[ -z $SSH_AGENT_PID ]]; then
  eval $(ssh-agent)
  trap "kill -TERM $SSH_AGENT_PID" 0 1 2
fi

if [[ -n $SSH_AGENT_PID ]]; then
  ssh-add || :
fi

function get-branches {
  git for-each-ref | awk -F' ' -f <(
    cat <<EOF
/refs\/remotes\/$remote\// {
  b = gensub(/refs\/remotes\/[^/]*\//, "", "g", \$3)
  if (b != "HEAD" && gensub(/^2019\//, "", "g", b) == b) {
    print b
  }
}
EOF
  )
}

function replant-branch {
  local dir="$1"
  local br=$2
  info "'$dir': Branch $br..."
  local lc=$(git log -n1 --format=%H "$br")
  local rc=$(git log -n1 --format=%H "$remote/$br")
  if [[ $lc != "$rc" ]]; then
    if git rev-list "$br" | grep "$rc" 1>/dev/null 2>/dev/null; then
      warn "'$dir': Branch $br is newer than remote"
    else
      if git fetch $remote $br:$br; then
        :
      else
        if git branch -m "$br" "$br@" --; then
          git checkout "$br" -- ||
            git checkout --track "$remote/$br" ||
            die "'$dir': Failed to checkout new commit"
        else
          die "'$dir': Backup branch $br failed"
        fi
      fi
      if git branch | grep "$br@" 2>/dev/null 1>/dev/null; then
        git branch -d "$br@" ||
          warn "'$dir': Merge required on branch $br"
      fi
    fi
  fi
}

function update-repo {
  local dir=$1
  pushd $dir >/dev/null
  info "Processing directory $dir..."
  git fetch $remote
  git fetch $remote --tags
  for br in $(get-branches); do
    replant-branch "$dir" "$br"
  done
  popd >/dev/null
}

while [[ -n $1 ]]; do
  update-repo "$1"
  shift
done
