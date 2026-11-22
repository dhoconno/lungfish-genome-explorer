#!/bin/sh
# A stand-in for the docker command inside the container of the image the job needs. A container cannot start another
# one, and the container this script runs in is already the image, so docker run runs the job in place.
case "$1" in
  image) echo "sha256:4d1027a4dcd93e272ccbcaaf2a4c4e55d1db43b6160284a03de8957f38231560" ;;
  version) echo "29.9.2" ;;
  run)
    shift
    workdir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --rm) shift ;;
        --platform|--user|--volume) shift 2 ;;
        --workdir) workdir=$2; shift 2 ;;
        --env) export "$2"; shift 2 ;;
        *) break ;;
      esac
    done
    shift
    [ -z "$workdir" ] || cd "$workdir" || exit 1
    exec "$@" ;;
  *) echo "docker stand-in: unsupported command: $*" >&2; exit 2 ;;
esac
