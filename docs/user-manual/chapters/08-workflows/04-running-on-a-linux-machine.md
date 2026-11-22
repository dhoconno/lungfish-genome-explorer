---
title: Running on a Linux Machine
chapter_id: 08-workflows/04-running-on-a-linux-machine
audience: analyst
prereqs: [03-reads/01-importing-fastq, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 22
task: Write a plan folder for a Linux machine or an HTCondor pool, run it there, and adopt the returned run into your project.
tags: [workflows, linux, htcondor, plan-folder, staging, staged-reads, adopt, batch, cluster]
tools: [clumpify]
parameters_refs: []
entry_points:
  - "Import Center > Sequencing Reads > Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > Linux Run Result"
  - "Import Center > Sequencing Reads > RNA-seq Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > Single-cell Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > RNA-seq Linux Run Result"
  - "CLI: lungfish-cli import fastq --write-plan, lungfish-cli import fastq --adopt"
shots:
  - id: linux-plan-sheet
    caption: "The sheet the Plan for a Linux Machine card of the Import Center opens for the hg002-chr20 reads, showing Staging folder, Threads per job, and Clumpify memory (GB)."
  - id: linux-run-result-card
    caption: "The Sequencing Reads tab of the Import Center with the Linux Run Result card, which adopts a run that came back from a Linux machine."
  - id: adopted-run-runtime
    caption: "The Runtime block of the Inspector's Provenance section on a bundle adopted from a Linux run, with Steps ran on, Steps ran with, and Wall Time (Linux run)."
illustrations: []
glossary_refs: [terminal, shell, thread, process, exit-status, container, fastq, bundle, clumpify, read-clumping, sample-sheet, samplesheet, json, tsv, import-center, provenance, run-record, wall-time]
features_refs: [import.fastq-linux-plan, import.rnaseq-plan, import.rnaseq-adopt, provenance.inspector]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Writing a plan folder for a Linux machine or an HTCondor pool, running it there, and adopting the returned run into the project. -->

## What it is

### Plan folders, staging folders, and staged reads

### One Linux machine or an HTCondor pool

## Why you would do this

## Choosing a tool

## Before you start

## Procedure

### Write a plan folder with the Plan for a Linux Machine card

<!-- SHOT: linux-plan-sheet -->

### Copy the plan folder and stage the reads

### Run the plan on one Linux machine with run-local.sh

### Submit the plan to an HTCondor pool

### Release a held HTCondor job

### Copy the returned run back to the Mac

### Adopt the returned run with the Linux Run Result card

<!-- SHOT: linux-run-result-card -->

## Settings

### Plan for a Linux Machine settings

## Reading the results

### The plan folder and its README

### The adopted bundle and its Runtime section

<!-- SHOT: adopted-run-runtime -->

## What good looks like

## On the command line

## Next
