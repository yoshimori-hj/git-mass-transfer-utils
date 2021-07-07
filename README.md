# git-mass-transfer-utils

## `full-update.sh`

Pull from remote repository and create local branches to points the
remote repository for all remote branches. If the name already exists
and not ff, local branches will be renamed with adding `@` on tail.

```
Usage: ./full-update.sh [-r remote] DIRS...

Run git pull on each working-copies on DIRS and replace current
branch to the remote one. And if conflict to local branch (not ff),
the local branch is left with adding '@' on tail.

If you are using public-key authentification for ssh connections,
this script invokes ssh-agent and you can skip inputting the passphrase
every time.
```

## `full-push.sh`

This scripts just run following for all given repositories.

```
git push $remote --all
git push $remote --tags
```

## `make-bundle.sh`

Same functionality for `full-update.sh` over machines without direct
network connectivity. Using git bundles for transfer.

```
nables file-based tranfer of git bundles like `git push --mirror` easily

Usage: ./make-bundle.sh commands...
       ./make-bundle.sh create -l REF-LIST REPOSITORY...
       ./make-bundle.sh unbundle -d BUNDLE-DIR -l REF-LIST REPOSITORY...
       ./make-bundle.sh list -l REF-LIST REPOSITORY...
       ./make-bundle.sh help

Typical workflow is following:

1. local: make ref-list of repositories:
   `./make-bundle.sh list -l some-list.lst repository`
2. Send the list to remote host
3. remote: create the bundle with the list:
   `./make-bundle.sh create -l some-list.lst repository`
4. Receive the list and bundles from remote host
5. local: unbundle the bundle:
   `./make-bundle.sh unbundle -l some-list.lst -d .../bundles repository`

# `create` command: creates git bundle.

Usage: ./make-bundle.sh create -l REF-LIST REPOSITORY...

Options:
  -d DIR        Output directory of bundle files
  -l FILE       refs list on remote repository
     REPOSITORY repositories to process

Note: refs list will be overwritten.

# `unbundle` command: extract data from git bundle and merge

Usage: ./make-bundle.sh unbundle -d BUNDLE-DIR -l REF-LIST REPOSITORY...

Options:
  -d DIR        Input directory of bundle files
  -l FILE       refs list on remote repository
     REPOSITORY repositories to process

Note: If commits are not fast-forward, the local branch will be
      renamed with postfix `@`.

# `list`: Make ref-list for local repository

Usage: ./make-bundle.sh list -l REF-LIST REPOSITORY...

Options:
  -l FILE       output filename
     REPOSITORY repositories to process
```
