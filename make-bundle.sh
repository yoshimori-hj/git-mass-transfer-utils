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

function help {
  cat <<EOF >&2
Enables file-based tranfer of git bundles like \`git push --mirror\` easily

Usage: $0 commands...
       $0 create -l REF-LIST REPOSITORY...
       $0 unbundle -d BUNDLE-DIR -l REF-LIST REPOSITORY...
       $0 list -l REF-LIST REPOSITORY...
       $0 help

Typical workflow is following:

1. local: make ref-list of repositories:
   \`$0 list -l some-list.lst repository\`
2. Send the list to remote host
3. remote: create the bundle with the list:
   \`$0 create -l some-list.lst repository\`
4. Receive the list and bundles from remote host
5. local: unbundle the bundle:
   \`$0 unbundle -l some-list.lst -d .../bundles repository\`

# \`create\` command: creates git bundle.

Usage: $0 create -l REF-LIST REPOSITORY...

Options:
  -d DIR        Output directory of bundle files
  -l FILE       refs list on remote repository
     REPOSITORY repositories to process

Note: refs list will be overwritten.

# \`unbundle\` command: extract data from git bundle and merge

Usage: $0 unbundle -d BUNDLE-DIR -l REF-LIST REPOSITORY...

Options:
  -d DIR        Input directory of bundle files
  -l FILE       refs list on remote repository
     REPOSITORY repositories to process

Note: If commits are not fast-forward, the local branch will be
      renamed with postfix \`@\`.

# \`list\`: Make ref-list for local repository

Usage: $0 list -l REF-LIST REPOSITORY...

Options:
  -l FILE       output filename
     REPOSITORY repositories to process

EOF
}

command=$1
if [[ -z $command ]]; then
  help
  exit 1
fi
case "$command" in
help | -h | --help)
  help
  exit 1
  ;;
list | create | unbundle) ;;

*)
  die "Unknown command '$command'"
  ;;
esac
shift

function opt_parse {
  local options=$1
  shift
  while l=$1; do
    case "$l" in
    --)
      shift
      break
      ;;
    -*)
      n=${options/:$1:/:$2:}
      if [[ $n == "$options" ]]; then
        die "Unknown argument '$l'"
      fi
      if [[ -z $2 ]]; then
        die "Parameter missing for option '$l'"
      fi
      if [[ ${2/:/;} != "$2" ]]; then
        die "Parameter cannot contain a colon for '$l'. Please try another name."
      fi
      options="$n"
      shift 2
      ;;
    *)
      break
      ;;
    esac
  done
  if [[ $# -lt 1 ]]; then
    die "No repository given for processing"
  fi
  echo "$options" "$@"
}

function list {
  opt=$1
  shift
  list_file=$(echo "$opt" | cut -f2 -d:)
  f=$(realpath $(mktemp))
  trap "rm -f $f" 0 1 2
  while repo=$1 && shift; do
    info "Processing $repo..."
    pushd "$repo" >/dev/null
    reponame="$(basename "$(realpath "$repo")")"
    git rev-list --all | sort | sed -e "s/^/$reponame /" >>$f
    popd >/dev/null
  done
  cp $f $list_file
  rm -f $f
  info "Done!"
}

function create_bundle {
  opt=$1
  shift
  list_file=$(echo "$opt" | cut -f2 -d:)
  bundle_dir=$(echo "$opt" | cut -f3 -d:)
  f=$(realpath $(mktemp))
  trap "rm -f $f" 0 1 2
  while repo=$1 && shift; do
    info "Processing $repo..."
    reponame="$(basename "$(realpath "$repo")")"
    pushd "$repo" >/dev/null
    git for-each-ref --format "${reponame} %(objectname) %(refname:rstrip=-2) %(refname:lstrip=2)" refs/heads refs/tags >>$f ||
      die "Failed to obtain refs for $repo"
    popd >/dev/null
    refs=$(awk '{if($1=="'"${reponame}"'") print $2}' $f)
    r=1
    nots=
    for commit in ${refs}; do
      if ! grep -Fq $commit $list_file; then
        r=0
        break
      fi
    done
    if [[ $r -eq 1 ]]; then
      info "Bundle will be empty. Skip."
    else
      mkdir -p $bundle_dir
      bundle=$(realpath $bundle_dir/$reponame.bundle)
      nots=
      for commit in ${refs}; do
        hrefs=$(cd "$repo" && git rev-list --topo-order $commit --not $nots)
        for hcommit in ${hrefs}; do
          if grep -Fq $hcommit $list_file; then
            nots="$nots $hcommit"
            break
          fi
        done
      done
      if [[ -z $nots ]]; then
        m="complete bundle "
      else
        m=""
      fi
      info "Generating $m'$(basename $bundle)'..."
      pushd "$repo" >/dev/null
      git bundle create $bundle --branches --tags --not $nots
      popd >/dev/null
    fi
  done
  cp $f $list_file
}

function do_bundle_unbundle {
  local repo=$1
  local bundle=$2
  if [[ $bundle_unbundled == 0 ]]; then
    return
  fi
  if [[ ! -e "$bundle" ]]; then
    warn "$repo: A git bundle required to checkout required commits, but not found"
    return
  fi

  info "$repo: Extracting bundle..."
  git bundle unbundle $bundle ||
    die "$repo: Failed to unbundle $bundle"
  bundle_unbundled=0
}

function replant-branch {
  local target_repo=$1
  local bundle=$2
  local repo=$3
  local rc=$4
  local kind=$5
  local name=$6
  if [[ $repo != $target_repo ]]; then
    return
  fi

  if [[ $kind == "refs/heads" ]]; then
    kind=branch
  else
    kind=tag
  fi
  info "$repo: Processing $kind $name..."
  lc=$(git rev-parse $name || :)
  if [[ $lc != "$rc" ]]; then
    if [[ $kind == "branch" ]]; then
      if git branch --contain "$rc" 2>/dev/null | grep -Fq "$name"; then
        warn "$repo: Branch $name is newer than bundle (remote)"
      else
        do_bundle_unbundle "$repo" "$bundle"
        if git checkout "$name" --; then
          if git merge --ff-only $rc; then
            :
          else
            git branch -m "$name" "$name@" ||
              die "$repo: Failed to backup branch $name"
            git checkout -b "$name" $rc -- ||
              die "$repo: Failed to checkout new commit for $name"
          fi
        else
          git checkout -b "$name" $rc -- ||
            die "$repo: Failed to checkout new commit for $name"
        fi
      fi
    else
      if [[ -n "lc" ]]; then
        warn "$repo: Tag $name already exists with different commit"
        git tag $name@ $lc
        git tag -d $name
      fi
      do_bundle_unbundle "$repo" "$bundle"
      git tag $name $rc
    fi
  fi
}

function unbundle {
  opt=$1
  shift
  list_file=$(echo "$opt" | cut -f2 -d:)
  bundle_dir=$(echo "$opt" | cut -f3 -d:)
  while repo=$1 && shift; do
    info "Processing $repo..."
    reponame="$(basename "$(realpath "$repo")")"
    bundle=$(realpath $bundle_dir/$reponame.bundle)
    bundle_unbundled=1
    exec 99<$list_file
    pushd $repo >/dev/null
    while read LINE <&99; do
      eval "replant-branch $repo $bundle $LINE"
    done
    popd >/dev/null
    exec 99<&-
  done
}

function _make_bundle_list {
  opt=$(opt_parse ':-l:' $@)
  list $opt
}

function _make_bundle_create {
  opt=$(opt_parse ':-l:-d:' $@)
  create_bundle $opt
}

function _make_bundle_unbundle {
  opt=$(opt_parse ':-l:-d:' $@)
  unbundle $opt
}

if [[ $(type -t _make_bundle_$command) != "function" ]]; then
  die "Internal consistency error (command '$command' not implemented)"
fi

eval "_make_bundle_$command \"$@\""
