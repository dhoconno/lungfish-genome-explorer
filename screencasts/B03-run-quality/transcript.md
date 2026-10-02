# Judge a sequencing run

Filmed with Lungfish 2026.9.72. The narration is a synthetic voice.

This video uses the Human Reads demo project. Choose Help, then Demo Projects, and click Download and Open beside Human Reads. The video Your first project shows each step.

Click the HG002 reads under Imports. HG002 is a Genome in a Bottle reference sample, one of the most thoroughly sequenced human genomes. The cards across the top summarize all the reads in this file, how many reads and bases there are, how long the reads are, and their base quality.

Each base call gets a base quality score, also called a Phred score and written Q. It is the sequencer's estimate of the chance that the call is wrong. Q20 means a 1 in 100 chance. Q30 means a 1 in 1,000 chance.

Here 91 percent of base calls are Q30 or higher. For Illumina's long 250-base reads, the manufacturer's target is about 75 percent, so this run is well above it.

Click the Q / Position chart to open it. It plots base quality from the first base of each read to the last. Quality drops toward the end because, cycle by cycle, the copies of each fragment fall out of step and the signal blurs. Here the average stays above Q30 until base 243. Click outside the chart to close it.

Length Dist. peaks at 250 bases, because the run read 250 bases from each end of every fragment, called 2 by 250 paired-end sequencing. GC content, the share of bases that are G or C, is 39 percent. The human genome averages about 41 percent, and a 500 kb slice can differ.

Next, see these reads aligned to a slice of human chromosome 20, on the Videos page of the website.
