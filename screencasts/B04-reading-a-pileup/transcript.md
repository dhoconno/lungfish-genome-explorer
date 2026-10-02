# Reading a pileup

Filmed with Lungfish 2026.9.72. The narration is a synthetic voice.

This video uses the Human Mapping and Variants demo project, the version with results. Choose Help, then Demo Projects, and click Download and Open beside it. The video Your first project shows each step.

A pileup shows aligned reads stacked at their positions on the reference. Under Analyses, open the minimap2 result. minimap2 is the read aligner that placed each read. Select its row and click Focus. The curve shows read depth, the number of reads covering each base. Here the mean depth is about 45.

Type positions 2,050 to 2,350 into the position field above the viewer and press Return. Each read is now a bar. Bases that match the reference are drawn plain, and bases that differ are colored. A colored base in one read is usually a sequencing error. A column where many reads differ is a likely variant.

Most human chromosomes come in two copies, one from each parent, and the version of a base on each copy is an allele. At position 2,078 of this slice, every read has A where the reference has G, so both copies most likely carry A. This is homozygous alternate, written 1/1.

At 2,162, 28 of 51 reads have T instead of A, so one copy most likely carries T and the other the reference A. This is heterozygous, written 0/1, where 0 is the reference allele and 1 the alternate. The Variants tab below the viewer lists the variants a variant-calling program found, with their genotypes.

To learn more, read the manual chapter Reading an Alignment. More videos are on the Videos page of the website.
