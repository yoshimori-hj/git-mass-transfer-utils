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
if [[ -z "$command" ]]; then
	help
	exit 1
fi
case "$command" in
help | -h | --help)
	help
	exit 1
	;;
list | create | unbundle | replant-branch) ;;

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
			if [[ "$n" == "$options" ]]; then
				die "Unknown argument '$l'"
			fi
			if [[ -z "$2" ]]; then
				die "Parameter missing for option '$l'"
			fi
            if [[ "${2/:/;}" != "$2" ]]; then
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
        git for-each-ref --format "${reponame} %(objectname) %(refname:rstrip=-2) %(refname:lstrip=2)" refs/heads refs/tags >>$f || \
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
            if [[ -z "$nots" ]]; then
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

function unbundle {
    opt=$1
    shift
    list_file=$(echo "$opt" | cut -f2 -d:)
    bundle_dir=$(echo "$opt" | cut -f3 -d:)
    f=$(realpath $(mktemp))
    trap "rm -f $f" 0 1 2
    while repo=$1 && shift; do
        info "Processing $repo..."
        reponame="$(basename "$(realpath "$repo")")"
        bundle=$(realpath $bundle_dir/$reponame.bundle)
        awk '{if($1=="'"${reponame}"'") printf("%s\0", $0)}' $list_file >$f
        pushd $repo >/dev/null
        if [[ -r $bundle ]]; then
            info "Extracting bundle..."
            git bundle unbundle $bundle
        fi
        popd >/dev/null
        xargs -0 -n 1 -a $f bash $- $0 replant-branch
    done
}

function replant-branch {
    repo=$1
    rc=$2
    kind=$3
    name=$4
    if [[ "$kind" == "refs/heads" ]]; then
        kind=branch
    else
        kind=tag
    fi
    pushd $repo >/dev/null
    info "$repo: Processing $kind $name..."
    lc=$(git rev-parse $name || :)
    if [[ "$lc" != "$rc" ]]; then
        if [[ "$kind" == "branch" ]]; then
            if git rev-list "$name" | grep -Fq $rc; then
                warn "$repo: Branch $name is newer than bundle (remote)"
            else
                if git checkout "$name" --; then
                    if git merge --ff-only $rc; then
                        :
                    else
                        git branch -m "$name" "$name@" || \
                            die "$repo: Failed to backup branch $name"
                        git checkout -b "$name" $rc -- || \
                            die "$repo: Failed to checkout new commit for $name"
                    fi
                else
                    git checkout -b "$name" $rc -- || \
                        die "$repo: Failed to checkout new commit for $name"
                fi
            fi
        else
            if [[ ! -z "lc" ]]; then
                warn "$repo: Tag $name already exists with different commit"
                git tag $name@ $lc
                git tag -d $name
            fi
            git tag $name $rc
        fi
    fi
    popd
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
    unundle $opt
}

function _make_bundle_replant-branch {
    eval "replant-branch \"$@\""
}

if [[ $(type -t _make_bundle_$command) != "function" ]]; then
    die "Internal consistency error (command '$command' not implemented)"
fi

eval "_make_bundle_$command \"$@\""
