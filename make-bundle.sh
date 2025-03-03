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

realpath=$(type -p realpath || type -p grealpath || die "realpath or grealpath required")

function show_list_help {
    cat <<EOF >&2
Usage: $0 list -l REF-LIST-FILE REPOSITORY...

Options:
  -l FILE       output filename
     REPOSITORY repositories to process

EOF
}

function show_create_help {
    cat <<EOF >&2
Usage: $0 create -l REF-LIST-FILE -d DIR REPOSITORY...

Options:
  -d DIR        Output directory of bundle files
  -l FILE       refs list on remote repository
     REPOSITORY repositories to process

Note: refs list will be overwritten.

EOF
}

function show_unbundle_help {
    cat <<EOF >&2
Usage: $0 unbundle -d BUNDLE-DIR -l REF-LIST-FILE REPOSITORY...

Options:
  -d DIR        Input directory of bundle files
  -l FILE       refs list on remote repository
     REPOSITORY repositories to process

Note: If commits are not fast-forward, the local branch will be
      renamed with postfix \`@\`.

EOF
}

function help {
  cat <<EOF >&2
Enables file-based tranfer of git bundles like \`git push --mirror\` easily

Usage: $0 commands...
       $0 create -l REF-LIST-FILE REPOSITORY...
       $0 unbundle -d BUNDLE-DIR -l REF-LIST-FILE REPOSITORY...
       $0 list -l REF-LIST-FILE REPOSITORY...
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

EOF
  show_create_help
  cat <<EOF >&2
# \`unbundle\` command: extract data from git bundle and merge

EOF
  show_unbundle_help
  cat <<EOF >&2
# \`list\`: Make ref-list for local repository

EOF
  show_list_help
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

function escape {
  m="$1"
  echo \'"${m//\'/\'\\\'\'}"\'
}

function apply {
  cmd="$1"
  opts="$2"
  shift 2
  [[ $# -lt 1 ]] && die "No repositories given to process"
  OPTIND=1
  while true; do
    if [[ ! -z "$opts" ]]; then
      OPTIND=1
      while getopts "$opts" N; do
        :
      done
      args="${@:1:$((OPTIND-1))}"
      shift $((OPTIND-1))
    else
      args=
    fi
    repo="$1"
    shift || break
    reponame="$(basename "$($realpath "$repo")")"
    info "Processing $reponame..."
    pushd "$repo" >/dev/null
    eval "$cmd $(escape "$repo") $(escape "$reponame")"
    popd >/dev/null
  done
}

function list {
  file="$1"
  name="$3"
  git rev-list --all | sort | sed -e "s/^/$name /" >>"$file"
}

function _make_bundle_list {
  OPTIND=1
  list_file=
  while getopts "l:h?" N; do
    case "$N" in
      l)   list_file="$OPTARG";;
      ?|h) show_list_help; exit 2;;
    esac
  done
  shift $((OPTIND-1))

  [[ -z "$list_file" ]] && die "No list file name given"
  [[ ! -e "$list_file" || -f "$list_file" ]] ||
    die "$list_file: not a regular file"

  f=$($realpath $(mktemp))
  trap "rm -f $f" 0 1 2
  apply "list $(escape "$f")" "" "$@"
  cp $f "$list_file"
  rm -f $f
  info "Done!"
}

function create {
  f="$1"
  list_file="$2"
  bundle_dir="$3"
  repo="$4"
  name="$5"
  git for-each-ref --format "${name} %(objectname) %(refname:rstrip=-2) %(refname:lstrip=2)" refs/heads refs/tags >>$f ||
    die "Failed to obtain refs for $repo"
  refs=$(awk '{if($1=="'"${name}"'") print $2}' $f)
  r=1
  for commit in ${refs}; do
    if ! grep -Fq $commit "$list_file"; then
      r=0
      break
    fi
  done
  if [[ $r -eq 1 ]]; then
    info "Bundle will be empty. Skip."
    return
  fi
  mkdir -p "$bundle_dir"
  bundle=$($realpath "$bundle_dir/$name.bundle")
  nots=
  for commit in ${refs}; do
    hrefs=$(git rev-list --topo-order $commit --not $nots)
    for hcommit in ${hrefs}; do
      if grep -Fq $hcommit "$list_file"; then
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
  info "Generating $m'$(basename "$bundle")'..."
  git bundle create "$bundle" --branches --tags --not $nots
}

function _make_bundle_create {
  OPTIND=1
  list_file=
  bundle_dir=.
  while getopts "l:d:h?" N; do
    case "$N" in
      l)   list_file="$OPTARG";;
      d)   bundle_dir="$OPTARG";;
      ?|h) show_create_help; exit 2;;
    esac
  done
  shift $((OPTIND-1))

  [[ -z "$list_file" ]] && die "No list file given"
  if [[ -e "$list_file" ]]; then
    [[ ! -f "$list_file" ]] && die "$list_file: Not a regular file"
    [[ ! -r "$list_file" ]] && die "$list_file: Is not readable"
  fi

  [[ -z "$bundle_dir" ]] && die "No bundle directory given"
  [[ -e "$bundle_dir" && ! -d "$bundle_dir" ]] && die "$bundle_dir: Not a directory"

  bundle_dir=$($realpath "$bundle_dir")
  list_file=$($realpath "$list_file")
  f=$($realpath $(mktemp))
  trap "rm -f $f" 0 1 2
  apply "create $(escape "$f") $(escape "$list_file") $(escape "$bundle_dir")" \
        "" "$@"
  cp $f $list_file
}

function do_bundle_unbundle {
  local repo="$1"
  local bundle="$2"
  if [[ $bundle_unbundled == 0 ]]; then
    return
  fi
  if [[ ! -e "$bundle" ]]; then
    warn "$repo: A git bundle required to checkout required commits, but not found"
    return
  fi

  info "$repo: Extracting bundle..."
  git bundle unbundle "$bundle" ||
    die "$repo: Failed to unbundle $bundle"
  bundle_unbundled=0
}

function replant-branch {
  local target_repo="$1"
  local bundle="$2"
  local repo="$3"
  local rc="$4"
  local kind="$5"
  local name="$6"
  if [[ "$repo" != "$target_repo" ]]; then
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
  list_file="$1"
  bundle_dir="$2"
  repo="$3"
  name="$4"
  bundle="$bundle_dir/$reponame.bundle"
  bundle_unbundled=1
  exec 99<$list_file
  while read LINE <&99; do
    eval "replant-branch $(escape "$repo") $(escape "$bundle") $LINE"
  done
  exec 99<&-
}

function _make_bundle_unbundle {
  OPTIND=1
  list_file=
  bundle_dir=.
  while getopts "l:d:h?" N; do
    case "$N" in
      l)   list_file="$OPTARG";;
      d)   bundle_dir="$OPTARG";;
      ?|h) show_unbundle_help; exit 2;;
    esac
  done
  shift $((OPTIND-1))

  [[ -z "$list_file" ]] && die "No list file given"
  [[ ! -f "$list_file" ]] && die "$list_file: No such file"
  [[ ! -r "$list_file" ]] && die "$list_file: Is not Readable"

  [[ -z "$bundle_dir" ]] && die "No bundle diretory given"
  [[ ! -d "$bundle_dir" ]] && die "$bundle_dir: Not a directory"

  list_file="$($realpath "$list_file")"
  bundle_dir="$($realpath "$bundle_dir")"

  apply "unbundle $(escape "$list_file") $(escape "$bundle_dir")" "" "$@"
  info "Done!"
}

if [[ $(type -t _make_bundle_$command) != "function" ]]; then
  die "Internal consistency error (command '$command' not implemented)"
fi

_make_bundle_$command "$@"
