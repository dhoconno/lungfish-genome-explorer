# HTCondor job event logs and a submit file

Real files from CHTC's access point `oconnor-ap4000.chtc.wisc.edu` (HTCondor 26.1.0), copied unchanged. The event logs
are the classic text form, with times on the access point's clock (US Central, no zone written). They are the fixtures
of `HTCondorJobEventLogTests` and `HTCondorNodeJobFixtureTests` (CHTC program C4, lane H).

| File | Job | What it shows |
|---|---|---|
| `k4-job2-z3.log` | 592727.0, C3 lane K4, the 1,000,000-pair slice run by `lungfish-executor run --plan` in the C0 image on e4075 | Submit, transfers, 001 with its slot, two 006 updates, 005 with return value 0 and the `Partitionable Resources` table |
| `h2a-echo.log` | 593367.0, C4 lane H milestone 2 node job (a) on e4004 | A short container job that ended with return value 0 |
| `h2a-echo.sub` | 593367.0 | The submit file of job (a), whose `arguments` line is the one `HTCondorSubmitTemplate.render` writes for `HTCondorSubmitTemplateTests.input()` |
| `h2a-match-exp-arguments.txt` | 593367.0 | `condor_history 593367 -af MATCH_EXP_Arguments`, the arguments as the schedd expanded them on the matched slot |
| `h2b-hold.log` | 593368.0, node job (b) | A `$$(LgeNoSuchAttribute)` macro with no default: 012 held with `Cannot expand $$ expression (LgeNoSuchAttribute).`, then 009 after `condor_rm` |
| `h2c-vacate.log` | 593370.0, node job (c) | 001 on e2475, 004 after `condor_vacate_job` (`Job vacated by schedd`), 001 again on e4073, then 004 and 009 after `condor_rm` |

The jobs' submit files, scripts and outputs are kept in the program records,
`lungfish-phase-records/chtc-program/c4/lanes/H/ap/`.
