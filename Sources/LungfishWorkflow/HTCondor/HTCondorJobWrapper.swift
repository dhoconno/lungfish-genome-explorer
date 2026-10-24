// HTCondorJobWrapper.swift - The text of lge-job.sh, which every job of a CHTC batch runs (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The text of `lge-job.sh`, from K4's `job2-z3.sh` with four changes (C4-design section 4).
///
/// 1. It reads no machine ad. The node's facts arrive as `--site-fact` arguments that HTCondor expanded, and it drops a
///    fact whose value is ``HTCondorSubmitTemplate/unsetValue``, so the run record shows that fact as not recorded
///    (C4-02) and never a false value.
/// 2. It looks up `dirname`, `basename` and `readlink` on the PATH before anything else and exits 2, a refusal, when one
///    is missing. Never 3, which is the executor's interrupted run, so a bare image would be retried and read as an
///    interruption.
/// 3. It unpacks the plan tar and moves each transferred file (the executor, each database, the sample's reads) to its
///    plan path. The executor's own check then hashes every file against the plan.
/// 4. It `exec`s the executor from its plan path, so SIGTERM reaches the executor with no shell between.
///
/// Exit codes: 2 for a refusal before the executor starts and 64 for a usage error, which `retry_until` never retries,
/// and 1 for a failure to unpack or move a file, which another machine may not repeat.
public enum HTCondorJobWrapper {
    public static var fileName: String { HTCondorSubmitTemplate.wrapperFileName }

    /// The utilities the executor's tools look up on the PATH (`K4-Z2.md:84-87`).
    public static let requiredUtilities = ["dirname", "basename", "readlink"]

    public static var text: String {
        let name = fileName
        let plan = HTCondorSubmitTemplate.planFolderName
        let tar = HTCondorSubmitTemplate.planTarName
        let unset = HTCondorSubmitTemplate.unsetValue
        let refused = ExecutorExitCode.refused
        let failed = ExecutorExitCode.failed
        let usage = ExecutorExitCode.usage
        return #"""
        #!/bin/sh
        # \#(name) - written by Lungfish (HTCondorJobWrapper) for every job of a CHTC batch.
        # Usage: \#(name) <name>=<path>... -- [<executor argument>]...
        # Each <name> is a file HTCondor transferred into the scratch folder and <path> its place in the unpacked plan
        # folder. The first is the executor, which this script runs with exec. It reads no machine ad: the node's facts
        # arrive as --site-fact arguments that HTCondor expanded, and a fact whose value is \#(unset) is dropped, so the
        # run record shows it as not recorded. Exit \#(refused) is a refusal and \#(usage) a usage error, which retry_until
        # never retries, and \#(failed) a failure that may pass on another machine. It never exits 3, which is the
        # executor's interrupted run.
        set -u

        refuse() {
          echo "\#(name): $1 The executor did not start." >&2
          exit \#(refused)
        }

        fail() {
          echo "\#(name): $1 The executor did not start." >&2
          exit \#(failed)
        }

        usage() {
          echo "usage: \#(name) <name>=<path>... -- [<executor argument>]..." >&2
          exit \#(usage)
        }

        missing=""
        for utility in \#(requiredUtilities.joined(separator: " ")); do
          command -v "$utility" >/dev/null 2>&1 || missing="$missing $utility"
        done
        [ -z "$missing" ] || refuse "The container image has no$missing on the PATH, which the executor's tools need."

        [ -f \#(tar) ] || refuse "The scratch folder holds no \#(tar)."
        tar -xf \#(tar) || fail "\#(tar) did not unpack."
        rm -f \#(tar)
        [ -f \#(plan)/plan.json ] || refuse "\#(tar) holds no \#(plan)/plan.json."

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
          target=\#(plan)/$path
          mkdir -p "${target%/*}" || fail "The folder of $path could not be made."
          mv -f -- "$name" "$target" || fail "$name could not be moved to $path."
          [ -n "$executor" ] || executor=$path
        done
        [ "$#" -gt 0 ] && [ -n "$executor" ] || usage
        shift
        chmod +x "\#(plan)/$executor" || fail "The executor could not be made executable."

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
              *=\#(unset)) ;;
              *) set -- "$@" --site-fact "$fact" ;;
            esac
          else
            set -- "$@" "$argument"
          fi
        done

        cd \#(plan) || fail "The plan folder could not be entered."
        exec "./$executor" run --plan "$PWD/plan.json" "$@"

        """#
    }
}
