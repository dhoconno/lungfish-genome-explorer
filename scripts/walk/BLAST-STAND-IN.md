# BLAST rows of a walk, on the stand-in

A walk's BLAST rows run on `scripts/walk/blast_standin.py`, so no row counts on how fast NCBI answers or on which tied records it names (`docs/contracts/SCOPE-AND-DELIVERY.md`, row Live services). The stand-in serves reply bodies recorded from real searches, in `Tests/Fixtures/blast-replies/`, and a person chooses what each search does. A verdict on the stand-in comes from the recorded reply and says nothing about the reads you picked, so these rows check words and outcomes and never a science number. A real search at the walk is a smoke, and any honest ending passes it.

## Bring it up

Run these from the repository, on the commit of the package.

1. Build the Debug CLI of that commit.

   `swift build --skip-update --product lungfish-cli`

2. Start the stand-in in a terminal of its own. It answers on 127.0.0.1 only and prints its address.

   `python3 scripts/walk/blast_standin.py --port 18765`

3. Make an empty folder for the walk's searches, such as `/tmp/blast-walk`. It takes the place of `<root>/blast/`, so a walk never touches the real one.

4. Open the packaged app with three variables. Repeat all three at every relaunch.

   `open -n --env LUNGFISH_CLI_PATH=<repository>/.build/debug/lungfish-cli --env LUNGFISH_BLAST_STAND_IN_ORIGIN=http://127.0.0.1:18765 --env LUNGFISH_BLAST_STAND_IN_STATE=/tmp/blast-walk "<packaged app>"`

Set no time scale. The packaged app's monitor reads the wall clock, so a copy goes out at 3 and 6 minutes and a search with every send held parks at about 9 minutes. `LUNGFISH_BLAST_STAND_IN_TIME_SCALE` is for tests whose monitor shares the child's clock.

The first step of the walk proves two things that no test can. The notarized app must run the unsigned Debug child, and `open --env` must reach it. If either fails, `ARCH-BLAST-RESILIENCE` section 7 names the fallback, a seeded folder in state `fetching` with its saved reply, marked `origin: standIn`.

A control is one request, such as `curl -s http://127.0.0.1:18765/control/release`. `control/state` says what has come so far, and `control/clear` takes away every fault. The stand-in starts with searches held. `control/reply?name=rotavirus-three-reads` serves another recorded pair. Each send gets the next reply of the pair, so a copy names other tied records.

Use a throwaway project for these rows. A search there is marked as the stand-in's, so a run with none of the variables that opens the project leaves it alone and says so.

## One row for each state

Press Verify with BLAST on any result row, with the stand-in as the row says. The words in each row of `UX-BLAST-WORDS` Q1 are what a person must read on the Operations row. The pane says the same under its heading.

Press Verify with BLAST on a result row of the throwaway project, any classifier result with a few reads. The verdict comes from the recorded reply, so counts such as "3 contradicting" belong to the stand-in and are not an error.

Make the first send one read. Row 2 must read request ID WALK1. A request ID that does not start with WALK means the variables did not reach the app and that search went to NCBI. Quit LGE and start again at step 4 of the bring-up.

| Q1 row | State | Do this | Read this |
|---|---|---|---|
| 1 | Sending | `control/slow-put?seconds=30`, then send. `control/clear` after | Status Running, `Sending <n> <noun> to NCBI` |
| 2 | Sent | `control/hold`, then send | `NCBI has the search, request ID WALK<n>` |
| 3 | Waiting | Hold on from row 2 for a minute | `Waiting for NCBI, request ID WALK<n>. Last checked <T>` |
| 4 | Sent again | Hold on from row 2 past 3 minutes | `Waiting for NCBI, <k> sends so far. Last checked <T>`, with the pane on `sent the same <noun> again` |
| 5 | Every send waiting | Hold on from row 2 past 9 minutes | Status Waiting, `Waiting at NCBI since <T>, 3 sends`, no spinner, and Quit raises no alert for it |
| 6 | Guard holds later sends | Let two held searches reach row 5, then send a third and hold on past 9 minutes | `LGE sends nothing again before <T>` |
| 7 | Back with a result | On a waiting row, `control/release` | Status Completed with no press, the counts, then `Collected <dur> after the first send, <k> sends`, and the pane on that row shows the results |
| 8 | NCBI expired it | `control/expire`, then send and hold on past 5 minutes | Status Failed, `NCBI no longer holds this search, request ID WALK<n>. No result. Choose Send Again` |
| 9 | NCBI failed it | `control/fail?words=Message%20ID%2099`, then send | Status Failed, `NCBI could not finish this search, request ID WALK<n>: Message ID 99` |
| 10 | Stopped by the person | On a waiting row, press Stop | Status Cancelled, `Stopped. LGE no longer checks this search. Choose Resume to check it again` |
| R1 | Checks not reaching NCBI | On a row in row 5, `control/fault?on=status&kind=drop&count=99`, then Check Now, wait a minute, Check Now, wait a minute, Check Now | Row 5's words, then `LGE could not reach NCBI at the last <c> checks and keeps trying` |
| R2 | Not sent, no connection | Stop the stand-in, then send. Start it again after | The row stays Running or Waiting and reads `Not sent yet. This Mac could not reach NCBI, so nothing went out. LGE tries again at <T>`. It never turns Failed. With the stand-in started again, the next try sends the search and row 2 follows |
| R3 | Not sent, NCBI refused | `control/fault?on=put&kind=503&count=99`, then send. `control/clear` after | Status Failed, `Not sent. NCBI answered with error 503 <t> times` |
| R4 | Send not confirmed | `control/fault?on=put&kind=drop&count=1`, then send | `NCBI did not confirm it got this search. LGE sends it once more at <T>` |
| R5 | Reply unreadable | `control/fault?on=result&kind=html&count=99`, then `control/ready` and send. `control/clear` after | Status Waiting, `NCBI finished this search, but its reply could not be read` |

## Relaunch of a waiting search

1. Bring a search to row 5, and read its request IDs in `control/state`.
2. Quit LGE. No alert names the search.
3. Run the open command again with the same three variables.
4. The row is back with its first start time, and the search goes on with the same request IDs. `control/state` shows no new Put.
5. `control/release`, and read row 7 on that row with no press.

## A quit while a send is unanswered

1. `control/slow-put?seconds=120`, then send. The row reads Sending.
2. Quit LGE. No alert names the search.
3. `control/clear`, then run the open command again.
4. The row is back and the search goes out. `control/state` shows a second Put, and `control/release` brings row 7.

A quit in the first moment after a press, before the search is saved in its folder, raises the alert and names the row, since that search would be lost.

## The smoke

Quit LGE, and open the packaged app again with none of the three variables. Send one small search from a result row. The packaged CLI then meets NCBI. Any honest ending passes, a result, a waiting row or NCBI's own words, and no time is a fault of this row.
