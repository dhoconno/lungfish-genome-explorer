// ExecutorPlanBatchReadme.swift - README.txt of a batch: how to run it on either launcher and bring it home (C5 lane LAUNCH)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The text of a batch's `README.txt`, the lab's commands for both launchers: `run.dag` on an HTCondor pool and
/// `run-local.sh` on one Linux machine, the steps for a held job in UX's words (C5 D14), and the one copy step and the
/// whole-batch adopt in the BADOPT ruling's order. It names no site (O41), and every path and number in it is the batch's
/// own: the staging folder, the batch's name, the image and the most jobs at once (C5 D13).
package enum ExecutorPlanBatchReadme {
    package static let fileName = "README.txt"

    package static func text(layout: ExecutorPlanStagingLayout, image: ExecutorPlanImageFile, maxJobs: Int) -> String {
        let batch = layout.batch
        let staging = layout.folder
        let returned = "\(layout.batchFolder)/<sample>/\(HTCondorSubmitTemplate.resultFolderName)/"
        let script = LinuxRunScript.fileName
        let jobs = LinuxRunScript.jobsFileName
        let logs = HTCondorSubmitTemplate.logsFolderName
        let result = HTCondorSubmitTemplate.resultFolderName
        let record = HTCondorSubmitTemplate.runRecordName
        let dag = HTCondorDAG.fileName
        return """
        \(fileName) - how to run the batch \(batch) and bring its results back to the Mac. Written by Lungfish.

        This folder holds one plan for each sample, in a folder named by the sample, and two ways to run
        them: on an HTCondor pool with \(dag), or on one Linux machine with Apptainer or Docker with
        \(script). \(jobs) lists the samples, one row each. staging-files.json lists the files the jobs
        read, each with its size, its SHA-256 and the file on the Mac to copy.


        Run on an HTCondor pool

        1. Copy each file staging-files.json lists to its stagingPath, below \(staging).

        2. Copy this folder to the machine you submit from, and run this from inside it:

           condor_submit_dag \(dag)

           Each sample's job returns its files to \(returned)
           and its step logs to <sample>/\(logs)/ in this folder.

        \(dag) runs at most \(maxJobs) jobs at once, from its line MAXJOBS lge \(maxJobs). To change that, edit the
        number on that line before you submit.

        The jobs ask for machines that reach the staging folder, run EL9 or later and are x86-64. On another
        pool, write the batch again with --job-requirements '<expression>', which replaces that whole
        requirements line of sample.sub. A sample sheet, samples.csv, is comma-separated; its request_disk
        column, in whole GB, sets that sample's disk request in place of the size Lungfish works out.


        If a sample's job is held

        A held job stops and waits, and the batch does not finish until you deal with it.

        1. See which sample is held, and why:

           condor_q -hold -af ClusterId ProcId DAGNodeName HoldReason

           Each line gives the job's two numbers, the sample's name and the reason HTCondor gave.
           To see every sample's state, read \(dag).status.

        2. Fix what the reason names. If it says an output file could not be sent back, that sample's
           job returned no reads. Read its log, <sample>/\(logs)/ in this folder, to see which step stopped.

        3. Remove the held job. HTCondor counts that sample as failed and goes on with the others:

           condor_rm <ClusterId>.<ProcId>

        4. When the other samples have finished, the run stops and writes \(dag).rescue001, which lists
           the samples still to run. Run the batch again from this folder:

           condor_submit_dag \(dag)

           HTCondor reads the rescue file and runs only those samples.

        5. When every sample has finished, copy the results back to the Mac and adopt the batch, as
           "Bring the results back to the Mac" says below.


        Run on one Linux machine with Apptainer or Docker

        1. Copy this folder to the Linux machine.

        2. Make a data folder there that holds the files staging-files.json lists, each at its stagingPath
           with \(staging)/ taken off the front: images/, shared/ and batches/\(batch)/.

        3. Run one of these from inside this folder:

           sh \(script) --runtime apptainer --data <data folder>
           sh \(script) --runtime docker --image <image> --data <data folder>

           Apptainer runs images/\(image.fileName) of the data folder, once its SHA-256 matches the plans.
           Docker runs <image>, that file unpacked into a Docker image for linux/amd64.

        \(script) runs at most \(maxJobs) samples at once, the same number as \(dag); --jobs <n> changes it.
        --sample <name> runs one sample. Each sample works in its own folder under scratch/ in this folder,
        or under --scratch <folder>, which needs the free space of the sample's request_disk in \(dag).

        Each sample leaves <sample>/\(result)/ with its run record, its reports and its reads, and
        <sample>/\(logs)/ with its step logs. \(logs)/<sample>.out and \(logs)/<sample>.err hold the run's output.
        \(script) skips a sample that has a \(result)/ folder, so running it again runs only the samples
        that returned nothing. Delete a sample's \(result)/ folder to run that sample again.


        Bring the results back to the Mac

        1. The adopt reads one folder for each sample: the plan.json your Mac wrote, with the job's
           files beside it.

        2. For every sample, copy the files inside \(result)/ into that sample's folder on the Mac, next to
           plan.json. It is one step for both launchers and only the source differs: after an HTCondor
           run, \(returned) on the machine that holds the staging folder; after a run of \(script), the Linux
           machine's <sample>/\(result)/ in this folder. The slash after \(result) matters. Run this on the Mac,
           from the folder that holds \(batch):

           for sample in $(grep -v '^#' \(batch)/\(jobs) | cut -f 1); do rsync -a <source>/"$sample"/\(result)/ \(batch)/"$sample"/; done

           <source> is <host>:\(layout.batchFolder) after an HTCondor run, or <host>:<this folder on the
           Linux machine> after a run of \(script).

        3. Do not copy \(logs)/, since the adopt reads no log. Do not copy a plan.json back from the Linux
           side, since the adopt must read the one the Mac wrote.

        4. Adopt the whole folder:

           lungfish-cli import fastq \(batch) --adopt --project <project>

           A batch is adopted whole: when any sample is refused, nothing is imported and each refused
           sample is listed by name. Fix or rerun it, then adopt the whole batch again. These are the
           three lines you may meet:

           <sample>: its job returned nothing. The folder holds no \(record).
             (a held or removed job, or a copy not made)
           <sample>: its job returned no reads. The payload <path> is missing from the folder.
           <sample>: The job's files are in the folder \(result). Copy everything inside \(result) into the folder <sample>, next to plan.json.

        5. When the adopt stops after some samples (a full disk, a cancel), the bundles it made stay
           whole and are named in the message: delete them from the project and adopt the batch again.
           The message says: To adopt the rest, delete the imported bundles and adopt the batch again.

        """
    }
}
