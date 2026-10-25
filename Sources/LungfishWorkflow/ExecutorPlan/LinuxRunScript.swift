// LinuxRunScript.swift - jobs.tsv and run-local.sh, the plain Linux launcher of a batch (C5 lane LAUNCH)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// One sample's row of `jobs.tsv`: its name, its plan tar in the submit folder with the tar's SHA-256, and each file its
/// job reads as `<path below the staging folder>=<plan path>`, the executor first, then each database, then the reads,
/// the order `lge-job.sh` takes them.
package struct LinuxRunJob: Sendable, Equatable {
    package var sample: String
    package var planTarPath: String
    package var planTarSHA256: String
    package var placements: [String]
}

/// The plain launcher of a batch (C5 S2, D10, D13): `jobs.tsv`, one row a sample, and `run-local.sh`, which runs each
/// sample's plan on one Linux machine with `apptainer exec` or `docker run`, at most `--jobs` at once, and leaves what an
/// HTCondor run returns: `<sample>/result/` with the run record, each report and the payload and nothing else, and
/// `<sample>/logs/` beside it, so one copy step brings either launcher's results to the Mac (ARCH-c5 point 1, BADOPT
/// ruling). The container runs `lge-job.sh` unchanged, so the executor starts the same way on both launchers. Each value
/// reaches the container as one argument through `"$@"`, and no field of `jobs.tsv` is run as shell text.
package enum LinuxRunScript {
    package static let fileName = "run-local.sh"
    package static let jobsFileName = "jobs.tsv"
    /// The launcher's version, which its `Launcher` site fact records after its name.
    package static let version = 1

    /// The `Launcher` site fact's value.
    package static var launcher: String { "\(fileName)/\(version)" }

    /// The text of `jobs.tsv`: one `#` line naming the columns, then one tab-separated row a sample.
    package static func jobsTable(_ jobs: [LinuxRunJob]) -> String {
        let header = "# sample\tplan tar\tplan tar SHA-256\t<file below the data folder>=<plan path>..."
        let rows = jobs.map { ([$0.sample, $0.planTarPath, $0.planTarSHA256] + $0.placements).joined(separator: "\t") }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    /// The text of `run-local.sh` for one batch. `image` is the SIF the plans pin, which an Apptainer run checks by its
    /// SHA-256 once a batch and runs from the data folder's `images/` unless `--image` names another copy. `resultPaths`
    /// are the files a job returns into `result/`, each at its plan path
    /// (``HTCondorSubmitTemplate/resultRelativePaths(payloadRelativePath:reportRelativePaths:)``), and `maxJobs` is the
    /// default of `--jobs`, the value of `run.dag`'s `MAXJOBS` (C5 D13).
    package static func text(batch: String, image: ExecutorPlanImageFile, resultPaths: [String], maxJobs: Int) -> String {
        typealias Fact = HTCondorSubmitTemplate.PlainLauncherFact
        let name = fileName
        let jobsFile = jobsFileName
        let wrapper = HTCondorJobWrapper.fileName
        let tar = HTCondorSubmitTemplate.planTarName
        let plan = HTCondorSubmitTemplate.planFolderName
        let result = HTCondorSubmitTemplate.resultFolderName
        let record = HTCondorSubmitTemplate.runRecordName
        let logs = HTCondorSubmitTemplate.logsFolderName
        let unset = HTCondorSubmitTemplate.unsetValue
        let refused = ExecutorExitCode.refused
        let usage = ExecutorExitCode.usage
        let usageLine = "usage: sh \(name) --runtime apptainer|docker --data <folder> [--image <image>] [--jobs <n>] "
            + "[--sample <name>] [--scratch <folder>]"
        return #"""
        #!/bin/sh
        # \#(name) - written by Lungfish (LinuxRunScript) for the batch \#(batch).
        # \#(usageLine)
        # It runs each sample's plan of \#(jobsFile) on this Linux machine in the batch's container image, at most <n> at
        # once (\#(maxJobs) when --jobs is not given, the number of MAXJOBS in run.dag). The data folder holds the files
        # staging-files.json lists, each at its path below the staging folder: images/, shared/ and batches/\#(batch)/.
        # Each sample's files are copied, never linked, into its own scratch folder, where \#(wrapper) unpacks the plan
        # and starts the executor as a job of an HTCondor pool does. A sample leaves <sample>/\#(result)/ with the run
        # record, each report and the reads and nothing else, <sample>/\#(logs)/ with the step logs, and
        # \#(logs)/<sample>.out and \#(logs)/<sample>.err with the run's output. A sample with a \#(result)/ folder is
        # skipped. Exit 0 when every sample finished or was skipped, 1 when one did not finish, \#(refused) for a
        # refusal before any sample starts and \#(usage) for a usage error.
        set -u

        name=\#(name)
        tab=$(printf '\t')

        usage() {
          echo "\#(usageLine)" >&2
          exit \#(usage)
        }

        refuse() {
          echo "$name: $1 No sample ran." >&2
          exit \#(refused)
        }

        # Ends one sample's subshell when the sample could not start.
        stop() {
          echo "$sample: $1 The sample did not run." >&2
          [ -z "$work" ] || rm -rf "$work"
          exit 1
        }

        # The SHA-256 of a file.
        digest() {
          if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | cut -d ' ' -f 1
          else
            shasum -a 256 "$1" | cut -d ' ' -f 1
          fi
        }

        # One site fact, KEY=VALUE: the first line of the value with no control character, or \#(unset), which
        # \#(wrapper) drops, so the run record shows the fact as not recorded and never a false value.
        fact() {
          value=$(printf '%s\n' "$2" | sed -n 1p | tr -d '[:cntrl:]')
          [ -n "$value" ] || value=\#(unset)
          printf '%s=%s' "$1" "$value"
        }

        # A relative path of names, with no empty, . or .. part.
        inside() {
          case /$1/ in
            *//* | */./* | */../*) return 1 ;;
          esac
          return 0
        }

        runtime=""
        image=""
        data=""
        jobs=\#(maxJobs)
        only=""
        scratch=""
        while [ "$#" -gt 0 ]; do
          case $1 in
            --help)
              echo "\#(usageLine)"
              exit 0
              ;;
            --runtime | --image | --data | --jobs | --sample | --scratch)
              [ "$#" -ge 2 ] || usage
              case $1 in
                --runtime) runtime=$2 ;;
                --image) image=$2 ;;
                --data) data=$2 ;;
                --jobs) jobs=$2 ;;
                --sample) only=$2 ;;
                --scratch) scratch=$2 ;;
              esac
              shift 2
              ;;
            *) usage ;;
          esac
        done
        case $runtime in
          apptainer | docker) ;;
          *) usage ;;
        esac
        case $jobs in
          "" | *[!0-9]* | 0*) usage ;;
        esac
        [ "$jobs" -le 1000 ] || usage
        [ -n "$data" ] || usage

        # The data and scratch folders are read from the folder the script was started in, then the script works in its
        # own folder.
        [ -d "$data" ] || refuse "The data folder $data does not exist."
        data=$(cd "$data" && pwd) || refuse "The data folder $data could not be entered."
        own_scratch=""
        if [ -n "$scratch" ]; then
          [ -d "$scratch" ] || refuse "The scratch folder $scratch does not exist."
          scratch=$(cd "$scratch" && pwd) || refuse "The scratch folder $scratch could not be entered."
        fi
        if [ -n "$image" ] && [ -f "$image" ]; then
          image=$(cd "$(dirname "$image")" && pwd)/${image##*/} || refuse "The folder of the image $image could not be entered."
        fi
        here=$(cd "$(dirname "$0")" && pwd) || refuse "The folder of $name could not be entered."
        cd "$here" || refuse "The folder of $name could not be entered."
        [ -f \#(jobsFile) ] || refuse "This folder holds no \#(jobsFile), so run $name from the batch folder Lungfish wrote."
        [ -f \#(wrapper) ] || refuse "This folder holds no \#(wrapper), so run $name from the batch folder Lungfish wrote."
        if [ -z "$scratch" ]; then
          scratch=$here/scratch
          own_scratch=yes
          mkdir -p "$scratch" || refuse "The scratch folder $scratch could not be made."
        fi
        case $scratch in
          *:* | *,*) refuse "The scratch folder $scratch holds a : or a , which a container's folder binding cannot hold, so pass --scratch another folder." ;;
        esac
        command -v "$runtime" >/dev/null 2>&1 || refuse "The $runtime command is not on the PATH."
        if [ -n "$only" ]; then
          cut -f 1 \#(jobsFile) | grep -qxF -- "$only" || refuse "\#(jobsFile) has no sample $only."
        fi
        mkdir -p \#(logs) || refuse "The folder \#(logs) could not be made."

        # The image, checked once for the batch.
        if [ "$runtime" = apptainer ]; then
          [ -n "$image" ] || image=$data/images/\#(image.fileName)
          [ -f "$image" ] || refuse "The image $image does not exist."
          image_sha=$(digest "$image") || refuse "The image $image could not be read."
          [ "$image_sha" = \#(image.sha256) ] || refuse "The image $image has the SHA-256 $image_sha, not the batch's \#(image.sha256), so pass --image the batch's image \#(image.fileName)."
          version=$(apptainer --version 2>/dev/null | sed -n '1s/.* //p')
          runtime_fact=$(fact \#(Fact.containerRuntime.rawValue) Apptainer)
          image_fact=$(fact \#(Fact.imageSHA256.rawValue) "$image_sha")
        else
          [ -n "$image" ] || refuse "A Docker run needs --image, a Docker image for linux/amd64 made from the batch's image \#(image.fileName). The lab's launcher-tier.sh image command makes one."
          image_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null) || refuse "Docker has no image $image."
          version=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
          runtime_fact=$(fact \#(Fact.containerRuntime.rawValue) Docker)
          image_fact=$(fact \#(Fact.containerImageID.rawValue) "$image_id")
        fi
        # A bare version such as 1.3.4, with no build suffix.
        version=${version%%-*}
        version=${version%%+*}
        version_fact=$(fact \#(Fact.containerRuntimeVersion.rawValue) "$version")

        # The machine's facts. The operating system is the os-release ID and major version, such as almalinux9, read as
        # text and never run.
        machine_fact=$(fact \#(Fact.machine.rawValue) "$(uname -n 2>/dev/null)")
        arch_fact=$(fact \#(Fact.arch.rawValue) "$(uname -m 2>/dev/null)")
        os=""
        if [ -r /etc/os-release ]; then
          os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d "\"'")
          os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d "\"'")
          [ -z "$os_id" ] || os=$os_id${os_version%%.*}
        fi
        os_fact=$(fact \#(Fact.operatingSystem.rawValue) "$os")
        launcher_fact=$(fact \#(Fact.launcher.rawValue) \#(launcher))

        # Runs one sample in its own subshell: $1 its name, $2 its plan tar, $3 the tar's SHA-256, then each file its job
        # reads as <path below the data folder>=<plan path>.
        run_sample() {
          sample=$1
          tar=$2
          tar_sha=$3
          shift 3
          work=""
          if [ -e "$sample/\#(result)" ]; then
            echo "$sample: skipped, since $sample/\#(result)/ exists. Delete that folder to run the sample again."
            return 0
          fi
          inside "$tar" || stop "\#(jobsFile) names the plan tar $tar outside this folder."
          [ -f "$tar" ] || stop "This folder holds no $tar."
          work=$scratch/$sample
          rm -rf "$work"
          mkdir -p "$work" || stop "The scratch folder $work could not be made."
          cp "$tar" "$work/\#(tar)" || stop "$tar could not be copied to the scratch folder."
          [ "$(digest "$work/\#(tar)")" = "$tar_sha" ] || stop "$tar does not have the SHA-256 \#(jobsFile) gives, so it is not the plan Lungfish wrote."
          cp \#(wrapper) "$work/\#(wrapper)" || stop "\#(wrapper) could not be copied to the scratch folder."
          chmod 755 "$work/\#(wrapper)" || stop "\#(wrapper) could not be made executable."

          # Each file goes into the scratch folder by its last name, as a transfer names it, and the wrapper moves it to
          # its plan path.
          count=$#
          while [ "$count" -gt 0 ]; do
            placement=$1
            shift
            count=$((count - 1))
            case $placement in
              *=*) ;;
              *) stop "\#(jobsFile) holds $placement, which is not <file>=<plan path>." ;;
            esac
            source=${placement%%=*}
            path=${placement#*=}
            inside "$source" || stop "\#(jobsFile) names $source outside the data folder."
            [ -f "$data/$source" ] || stop "The data folder $data holds no $source."
            file=${source##*/}
            cp "$data/$source" "$work/$file" || stop "$source could not be copied to the scratch folder."
            set -- "$@" "$file=$path"
          done
          set -- "$@" -- --site-fact "$machine_fact" --site-fact "$arch_fact" --site-fact "$os_fact" \
            --site-fact "$runtime_fact" --site-fact "$version_fact" --site-fact "$image_fact" --site-fact "$launcher_fact"

          echo "$sample: started."
          if [ "$runtime" = apptainer ]; then
            apptainer exec --containall --no-home --bind "$work" --pwd "$work" --env "TMPDIR=$work" "$image" \
              ./\#(wrapper) "$@" </dev/null >"\#(logs)/$sample.out" 2>"\#(logs)/$sample.err" 3>&-
          else
            docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" --volume "$work:$work" --workdir "$work" \
              --env "TMPDIR=$work" "$image" ./\#(wrapper) "$@" </dev/null >"\#(logs)/$sample.out" 2>"\#(logs)/$sample.err" 3>&-
          fi
          status=$?

          # Only the run record, each report and the payload go to result/, and result/ is left only when the run
          # record came back, so a sample that returned nothing runs again next time.
          kept=$work/\#(result)
          mkdir -p "$kept"
          for path in \#(resultPaths.joined(separator: " ")); do
            [ -f "$work/\#(plan)/$path" ] || continue
            case $path in
              */*) mkdir -p "$kept/${path%/*}" ;;
            esac
            mv -f "$work/\#(plan)/$path" "$kept/$path"
          done
          if [ -d "$work/\#(plan)/\#(logs)" ]; then
            rm -rf "$sample/\#(logs)"
            mv "$work/\#(plan)/\#(logs)" "$sample/\#(logs)"
          fi
          [ ! -f "$kept/\#(record)" ] || mv "$kept" "$sample/\#(result)"
          rm -rf "$work"
          if [ "$status" -eq 0 ]; then
            echo "$sample: finished. Its files are in $sample/\#(result)/."
            return 0
          fi
          echo "$sample: the run stopped with exit $status. Read \#(logs)/$sample.err and $sample/\#(logs)/ to see which step stopped." >&2
          return 1
        }

        # At most $jobs samples at once: a pipe holds one line a free slot.
        failed=$scratch/failed.txt
        rm -f "$failed"
        pool=$scratch/slots.fifo
        rm -f "$pool"
        mkfifo "$pool" || refuse "The scratch folder $scratch could not hold a pipe."
        exec 3<>"$pool"
        rm -f "$pool"
        slot=0
        while [ "$slot" -lt "$jobs" ]; do
          echo >&3
          slot=$((slot + 1))
        done

        while IFS=$tab read -r sample tar tar_sha rest; do
          case $sample in
            "" | "#"*) continue ;;
          esac
          [ -z "$only" ] || [ "$sample" = "$only" ] || continue
          case $sample in
            *[!A-Za-z0-9_-]*)
              echo "$name: \#(jobsFile) holds the sample name $sample, which is not a name Lungfish writes." >&2
              echo "$sample" >>"$failed"
              continue
              ;;
          esac
          read -r slot <&3
          (
            (
              IFS=$tab
              set -f
              run_sample "$sample" "$tar" "$tar_sha" $rest
            ) || echo "$sample" >>"$failed"
            echo >&3
          ) &
        done <\#(jobsFile)
        wait
        exec 3>&-

        status=0
        [ ! -s "$failed" ] || status=1
        rm -f "$failed"
        [ -z "$own_scratch" ] || rmdir "$scratch" 2>/dev/null
        if [ "$status" -ne 0 ]; then
          echo "$name: some samples did not finish, each named above. Running $name again runs each sample with no \#(result)/ folder; delete a sample's \#(result)/ folder to run it again." >&2
          exit 1
        fi
        echo "$name: every sample finished or was skipped. Copy each <sample>/\#(result)/ to the Mac as \#(ExecutorPlanBatchReadme.fileName) says."
        exit 0

        """#
    }
}
