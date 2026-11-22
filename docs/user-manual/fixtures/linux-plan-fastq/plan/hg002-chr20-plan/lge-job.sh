#!/bin/sh
# lge-job.sh - written by Lungfish (HTCondorJobWrapper) for every job of an HTCondor batch.
# Usage: lge-job.sh <name>=<path>... -- [<executor argument>]...
# Each <name> is a file HTCondor transferred into the scratch folder and <path> its place in the unpacked plan
# folder. The first is the executor, which this script runs with exec. It reads no machine ad: the node's facts
# arrive as --site-fact arguments that HTCondor expanded, and a fact whose value is lge_unset is dropped, so the
# run record shows it as not recorded. Exit 2 is a refusal and 64 a usage error, and 1 a
# failure that may pass on another machine. It never exits 3, which is the executor's interrupted run.
set -u

refuse() {
  echo "lge-job.sh: $1 The executor did not start." >&2
  exit 2
}

fail() {
  echo "lge-job.sh: $1 The executor did not start." >&2
  exit 1
}

usage() {
  echo "usage: lge-job.sh <name>=<path>... -- [<executor argument>]..." >&2
  exit 64
}

missing=""
for utility in dirname basename readlink; do
  command -v "$utility" >/dev/null 2>&1 || missing="$missing $utility"
done
[ -z "$missing" ] || refuse "The container image has no$missing on the PATH, which the executor's tools need."

[ -f plan.tar ] || refuse "The scratch folder holds no plan.tar."
tar -xf plan.tar || fail "plan.tar did not unpack."
rm -f plan.tar
[ -f plan/plan.json ] || refuse "plan.tar holds no plan/plan.json."

executor=""
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  case $1 in
    *=*) ;;
    *) usage ;;
  esac
  name=${1%%=*}
  path=${1#*=}
  shift
  case $name in
    "" | . | .. | */*) refuse "A placement names no file of the scratch folder." ;;
  esac
  case /$path/ in
    *//* | */./* | */../*) refuse "The placement of $name leaves the plan folder." ;;
  esac
  [ -f "$name" ] || refuse "The scratch folder holds no $name."
  target=plan/$path
  mkdir -p "${target%/*}" || fail "The folder of $path could not be made."
  mv -f -- "$name" "$target" || fail "$name could not be moved to $path."
  [ -n "$executor" ] || executor=$path
done
[ "$#" -gt 0 ] && [ -n "$executor" ] || usage
shift
chmod +x "plan/$executor" || fail "The executor could not be made executable."

count=$#
while [ "$count" -gt 0 ]; do
  argument=$1
  shift
  count=$((count - 1))
  if [ "$argument" = "--site-fact" ] && [ "$count" -gt 0 ]; then
    fact=$1
    shift
    count=$((count - 1))
    case $fact in
      *=lge_unset) ;;
      *) set -- "$@" --site-fact "$fact" ;;
    esac
  else
    set -- "$@" "$argument"
  fi
done

cd plan || fail "The plan folder could not be entered."
exec "./$executor" run --plan "$PWD/plan.json" "$@"
