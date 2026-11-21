# Owner directions

Each row is a direction of the owner that still binds later sessions, in the owner's words (shortened with an ellipsis, never reworded) and with what it binds. A one-time answer is spent and has no row. Rows run by topic. An id with a prefix, such as 2.9 O5, is a row of that older plan.

| Id | Date | The owner's words | Binds |
|---|---|---|---|
| O171 | 2026-11-11 | "Have expert teams make any necessary decisions so this can keep going for the next 10 hours or so in my absence." | Experts decide in the owner's absence, a split takes the manager's pick |
| O173 | 2026-11-12 | "Let's promote the RNAseq phase to be next. ... we should be systematic, identifying well done manuscripts whose underlying data is available in SRA ... First we should do the analyses with bash and python scripts ..., then we should implement these analyses in the LGE CLI, and finally we should add the GUI interfaces ..." | RNA-seq is Phase 5, Biomark X Phase 6. A new topic reproduces published analyses on public SRA data by script, then CLI, then GUI |
| O175 | 2026-11-12 | "... we should have expert teams (including ad hoc RNAseq experts) adjudicate any issues." | Ad hoc RNA-seq experts sit with the panel on RNA-seq questions and decide in the owner's absence as O171 sets |
| O176 | 2026-11-12, 2026-11-14 | "Up to 1 TB" and "Yes, env on lge_scratch", then "Its fine to use more of the external SSD as needed for RNAseq files." | Open-access SRA, ENA and GEO data and one conda environment on lge_scratch, past 1 TB as needed with 200 GB kept free. No controlled-access data |
| O177 | 2026-11-14 | "Panel decides, I see splits" (monitor actions) | The panel rules on the monitor's open actions, the owner sees splits |
| O178 | 2026-11-14 | "CHTC, non-human data only" (RNA-seq Linux host) | LINUX-HOST gates run on a CHTC node. Human data only as O179 allows |
| O179 | 2026-11-16 | "Human RNA data can go to CHTC as long as there is no PHI. That's a user responsibility. SRA human data and coded human data can go to CHTC." | Narrows O178. Human RNA-seq data with no PHI (SRA or coded) may run on CHTC, the full-size gates of 5.3 included. Keeping PHI out is the user's job |
| O105 | 2026-10-31 | "Alerting me is not useful since I'm usually not watching this screen. The agent needs to manage memory pressure ..." | The agent handles memory pressure itself and never alerts the owner |
| O180 | 2026-11-16 | "... add to the contract that every few days we should review these folders and clear stale folders." (`~/LGE-GUI-Walk`) | Walk folders are reviewed every three days (MACHINES.md, Walk) |
| O126 | 2026-11-03 | "Yes, apply and push" | Standing go of SCOPE-AND-DELIVERY, in force when prompt or chat gives it |
| O159 | 2026-11-07 | "Go without me and also avoid the use of the term 'Stable' unless referencing a stable release, which we won't be building for several weeks." | No stable release without the owner's ask. Say Stable only for one |
| O78 | 2026-10-26 | "This is fine but don't worry too much about the budget. Focus on quality and reasonableness." | Budgets are soft and quality comes first. The five-builder cap holds |
| none, program plan | 2026-11-11 | "We use this instrument to do parentage assays using SNPs throughout the genome. We need to understand how genotypes are currently called with the BiomarkX software ..." | Biomark X follows RNA-seq as Phase 6 (O173) |
| none, review brief | 2026-11-11 | "After the revised plans land, I'll use Opus Max orchestrators with contracts specifying other types of lesser agents for implementation, as we do currently." | Managers run on opus at max, lesser agent types implement |
| O103 | 2026-10-31 | "xhigh" | Opus fix agents run at effort xhigh |
| none, memory note | 2026-10-15 | Words not on file. | Every delegation names its model and effort |
| O67 | 2026-10-26 | "Yes, we should push." | Audit contracts bind. The panel meets when a plan is written, and a short job has no monitor (review of 2026-11-11) |
| O75 | 2026-10-26 | "Have the experts convene a meeting and decide which to include by consensus" | Panel consensus picks older S1 and S2 backlog rows for a phase |
| O69 | 2026-10-26 | "Yes, we should keep the measurement contracts because ... this may change once new models become available." | The measurements and the weekly check are kept, in the records from the process job on |
| 2.12 O12 | 2026-10-18 | "We should also make sure that the Claude Code best practices ... are checked weekly ..." | Check the Claude Code best practices page weekly |
| 2.12 O10 | 2026-10-18 | "... when we get close to the quota we should by contract output a prompt I can use to resume in a new account that doesn't have this session's context" | Near the quota stop, write a resume prompt for a new account |
| 2.13 O26 | 2026-10-21 | "The notes have gotten excessively detailed. We should have the experts write more accessible notes anyway." | Release notes are short, plain and written for bench scientists |
| O181 | 2026-11-21 | "OK, we should also begin refreshing and improving the docs. ... have Claude Code revise the documents and screenshots to reflect all of the changes in Phases 1-5. ..." | Ends the O168 wait for the manual and screenshots. Screencasts still wait |
| 2.9 O5 | 2026-10-12 | "Use live computer tests when possible, with a fallback to the stand-ins as necessary." | Real tool runs first, stand-ins only where this Mac cannot run |
| O138 | 2026-11-03 | "... we should adjust the tests so they do not rely on predictable BLAST behavior ..." | Tests never count on a third-party service's speed or answer |
| CHTC O2 | 2026-10-21 | "Yes, we would not use human data, so HIPAA is not an issue." | No restricted read set goes to CHTC, checked for each batch |
| CHTC O42 | 2026-10-24 | "We also shouldn't be using a 60GB file for testing after we have the Linux tool operational. This would be wasteful." | The Linux tool is tested on small public read sets only |

The full history is in the owner tables of the plans, in git and in `~/lungfish-phase-records`. A direction not listed above is spent or replaced.
