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

    /// `stagedReads` says that reads of the batch are in the staging folder already (C6 ruling STAGED), which changes
    /// two passages, `listed` and `dataFolders`. A batch with no staged read keeps the text of ruling X6 (ARCH 7).
    package static func text(layout: ExecutorPlanStagingLayout, image: ExecutorPlanImageFile, maxJobs: Int,
                             stagedReads: Bool) -> String {
        let batch = layout.batch
        let staging = layout.folder
        let listed = stagedReads
            ? "staging-files.json lists the files the jobs read, each with its size and its SHA-256. Each file\n"
                + "other than the image and the reads also has a source, the file on the Mac to copy or link. The\n"
                + "image and the reads are in the staging folder already, and each job checks each read against its\n"
                + "size and SHA-256 before any step runs."
            : "staging-files.json lists the files the jobs read, each with its size and its SHA-256. Each file\n"
                + "other than the image also has a source, the file on the Mac to copy or link. The image is staged\n"
                + "already."
        let dataFolders = stagedReads
            ? "   the folders that hold the reads, and images/ for Apptainer. A Docker run reads no images/ folder.\n"
                + "   On a machine that reaches the staging folder, \(staging) can be the data folder."
            : "   batches/\(batch)/, and images/ for Apptainer. A Docker run reads no images/ folder. On a machine\n"
                + "   that reaches the staging folder, \(staging) can be the data folder."
        let returned = "\(layout.batchFolder)/<sample>/\(HTCondorSubmitTemplate.resultFolderName)/"
        let script = LinuxRunScript.fileName
        let jobs = LinuxRunScript.jobsFileName
        let logs = HTCondorSubmitTemplate.logsFolderName
        let result = HTCondorSubmitTemplate.resultFolderName
        let record = HTCondorSubmitTemplate.runRecordName
        let dag = HTCondorDAG.fileName
        return """
        \(fileName) - how to run the batch \(batch) and bring its results back to the Mac. Written by Lungfish.

        This folder holds one plan for each sample, in a folder named by the sample. It has two ways to run
        them. Use \(dag) on an HTCondor pool. Use \(script) on one machine with Apptainer or Docker, which
        can be a Linux machine or a Mac with Docker. \(jobs) lists the samples, one row each.
        \(listed)


        Run on an HTCondor pool

        1. For each file in staging-files.json that has a source, copy or link that source to the file's
           stagingPath, below \(staging). The name of a file in shared/ starts with its SHA-256, so a file
           already there with the listed size is the same file. Leave it, and never copy over it, since the
           jobs of other batches may be reading it.

        2. Copy this folder to the machine you submit from, and run this from inside it:

           condor_submit_dag \(dag)

           Each sample's job returns its files to \(returned)
           and its step logs to <sample>/\(logs)/ in this folder.

        \(dag) runs at most \(maxJobs) jobs at once, from its line MAXJOBS lge \(maxJobs). To change that, edit the
        number on that line before you submit.

        The jobs ask for machines that reach the staging folder, run EL9 or later and are x86-64. On another
        pool, write the batch again with --job-requirements '<expression>', which replaces that whole
        requirements line of sample.sub.

        The sample sheet of a batch is a comma-separated file, samples.csv, with a header line and one line for
        each sample. Lungfish reads it on the Mac, when it writes the batch with --samplesheet samples.csv.
        The columns sample, r1 and r2 name the sample and its two read files, and a relative path is read
        from the folder that holds the sheet. The optional column request_disk gives that sample's disk
        request in whole GB in place of the size Lungfish works out, and an empty cell keeps that size:

           sample,r1,r2,request_disk
           S1,S1_R1.fastq.gz,S1_R2.fastq.gz,40
           S2,S2_R1.fastq.gz,S2_R2.fastq.gz,


        If a sample's job is held

        A held job stops and waits, and the batch does not finish until you deal with it.

        1. See which sample is held, and why:

           condor_q -hold -af ClusterId ProcId DAGNodeName ExitCode HoldReason

           Each line gives the job's two numbers, the sample's name, the run's exit code and the reason
           HTCondor gave. To see every sample's state, read \(dag).status. In \(logs)/<sample>.log a hold
           shows as "Job was evicted" and then "Job was held". Both lines are one hold, not a move to
           another machine.

        2. If the exit code is 0, the run finished and only sending its files back failed. HTCondor starts
           that job again by itself, at most twice, so leave it. Otherwise fix what the reason names. If it
           says an output file could not be sent back, that sample's job returned no reads. Read its run
           record, \(returned)\(record), and its log, <sample>/\(logs)/ in this folder, to see which step
           stopped. A job the executor refuses before its first step leaves only the record. A job that
           lge-job.sh refuses leaves no record, so read \(logs)/<sample>.err.

        3. Running the sample again replaces its run record, so copy it aside if it is there. Then remove
           the held job. HTCondor counts that sample as failed and goes on with the others:

           cp \(returned)\(record) <sample>/run-record-<ClusterId>.json
           condor_rm <ClusterId>.<ProcId>

        4. When the other samples have finished, the run stops and writes \(dag).rescue001, which lists
           the samples still to run. Run the batch again from this folder:

           condor_submit_dag \(dag)

           HTCondor reads the rescue file and runs only those samples.

        5. When every sample has finished, copy the results back to the Mac and adopt the batch, as
           "Bring the results back to the Mac" says below.


        Run on one machine with Apptainer or Docker

        1. Copy this folder to the machine that runs it, a Linux machine or a Mac with Docker.

        2. Make a data folder there and copy or link into it each file staging-files.json lists, at its
           stagingPath with \(staging)/ taken off the front. That gives the folders shared/ and
        \(dataFolders)

        3. Run one of these from inside this folder:

           sh \(script) --runtime apptainer --data <data folder>
           sh \(script) --runtime docker --image <image> --data <data folder>

           Apptainer runs images/\(image.fileName) of the data folder, once its SHA-256 matches the plans.
           Docker runs <image>, a Docker image for linux/amd64 made from that same file. The lab's
           launcher-tier.sh image command makes one.

        \(script) runs at most \(maxJobs) samples at once, the same number as \(dag). --jobs <n> changes it.
        --sample <name> runs one sample. Each sample works in its own folder under scratch/ in this folder,
        or under --scratch <folder>, which needs the free space of the sample's request_disk in \(dag).

        Each sample leaves <sample>/\(result)/ with its run record, its reports and its reads, and
        <sample>/\(logs)/ with its step logs. \(logs)/<sample>.out and \(logs)/<sample>.err hold the run's output.
        Those are the logs of the job. \(script) prints its progress to its own output, a line when a
        sample starts and a line when it finishes. It prints none of the job's output.
        \(script) skips a sample that has a \(result)/ folder, so running it again runs only the samples
        that returned nothing. Delete a sample's \(result)/ folder to run that sample again.


        Bring the results back to the Mac

        1. The adopt reads one folder for each sample: the plan.json your Mac wrote, with the job's
           files beside it.

        2. For every sample, copy the files inside \(result)/ into that sample's folder on the Mac, next to
           plan.json. It is one step for both launchers, and only the source differs. After an HTCondor
           run the source is \(returned) on the machine that holds the staging folder. After a run of
           \(script) it is <sample>/\(result)/ in this folder on the machine that ran it. The slash after
           \(result) matters. Run this on the Mac, from the folder that holds \(batch):

           for sample in $(grep -v '^#' \(batch)/\(jobs) | cut -f 1); do rsync -a <source>/"$sample"/\(result)/ \(batch)/"$sample"/; done

           <source> is <host>:\(layout.batchFolder) after an HTCondor run, or <host>:<this folder on the
           machine that ran \(script)> after a run of \(script). When the files are on this Mac, <source>
           is that folder alone, with no <host>:. The rsync command reaches <host> through your ssh setup,
           so a name from your ssh config works.

        3. Do not copy \(logs)/, since the adopt reads no log. Do not copy a plan.json back from the Linux
           side, since the adopt must read the one the Mac wrote.

        4. Adopt the whole folder:

           lungfish-cli import fastq \(batch) --adopt --project <project>

           A batch is adopted whole: when any sample is refused, nothing is imported and each refused
           sample is listed by name. Fix or rerun it, then adopt the whole batch again. The project must
           not already hold a bundle with the name of a sample of the batch, and the adopt refuses that
           sample if it does. To start over, delete those bundles from the project and adopt the batch
           again. These are four of the lines you may meet:

           <sample>: its job returned nothing. The folder holds no \(record).
             (a held or removed job, or a copy not made)
           <sample>: its job returned no reads. The payload <path> is missing from the folder.
           <sample>: The job's files are in the folder \(result). Copy everything inside \(result) into the folder <sample>, next to plan.json.
           <sample>: The project already holds the bundle <bundle>.

        5. When the adopt stops after some samples (a full disk, a cancel), the bundles it made stay
           whole and are named in the message: delete them from the project and adopt the batch again.
           The message says: To adopt the rest, delete the imported bundles and adopt the batch again.

        """
    }
}
