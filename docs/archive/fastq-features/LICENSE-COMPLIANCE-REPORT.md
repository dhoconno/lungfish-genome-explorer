# Lungfish Genome Explorer -- Software License Compliance Report

**Date:** 2026-03-09
**Auditor:** Compliance Auditor (automated)
**Scope:** All embedded binaries, linked Swift packages, and externally invoked tools
**Repository License:** MIT (SPDX: MIT)

---

## 1. License Compatibility Matrix

The table below classifies each dependency by its license, integration method,
and compatibility with the Lungfish MIT license.

| # | Component | License | Integration Method | Compatible with MIT? |
|---|-----------|---------|-------------------|---------------------|
| 1 | SAMtools 1.22.1 | MIT/Expat | Embedded binary, subprocess | YES |
| 2 | HTSlib 1.22.1 | MIT/Expat | Embedded binary, subprocess | YES |
| 3 | BCFtools 1.22 | MIT/Expat | Embedded binary, subprocess | YES |
| 4 | UCSC Tools v469 | MIT | Embedded binary, subprocess | YES |
| 5 | SeqKit 2.9.0 | MIT | Embedded binary, subprocess | YES |
| 6 | fastp 1.1.0 | MIT | Embedded binary, subprocess | YES |
| 7 | cutadapt 4.9 | MIT (PyInstaller exception) | Embedded binary, subprocess | YES (see Section 2) |
| 8 | BBTools 39.13 | BBMap License (custom) | Embedded binary, subprocess | CONDITIONAL (see Section 2) |
| 9 | VSEARCH 2.29.2 | BSD-2-Clause / GPL-3.0 (dual) | Embedded binary, subprocess | YES under BSD-2-Clause (see Section 2) |
| 10 | pigz 2.8 | zlib | Embedded binary, subprocess | YES |
| 11 | OpenJDK Temurin 21 | GPL-2.0 + Classpath Exception | Embedded JRE, subprocess | YES under Classpath Exception (see Section 2) |
| 12 | Swift Argument Parser | Apache 2.0 | Compiled/linked | YES |
| 13 | Swift Collections | Apache 2.0 | Compiled/linked | YES |
| 14 | Swift Algorithms | Apache 2.0 | Compiled/linked | YES |
| 15 | Swift System | Apache 2.0 | Compiled/linked | YES |
| 16 | Swift Async Algorithms | Apache 2.0 | Compiled/linked | YES |
| 17 | Apple Containerization | Apache 2.0 | Compiled/linked | YES |
| 18 | minimap2 | MIT | External process (not embedded) | YES |
| 19 | BWA | GPL-3.0 | External/container (not embedded) | N/A -- not distributed |
| 20 | SPAdes | GPL-2.0 | Container (not embedded) | N/A -- not distributed |
| 21 | FastQC / MultiQC | GPL / GPL-3.0 | External/container (not embedded) | N/A -- not distributed |

**Summary:** No license is fundamentally incompatible, provided the specific
conditions analyzed in Section 2 are satisfied.

---

## 2. GPL Contamination Analysis

### 2.1 VSEARCH (dual BSD-2-Clause / GPL-3.0)

**Finding:** LOW RISK -- BSD-2-Clause applies.

VSEARCH is explicitly dual-licensed. The VSEARCH README and LICENSE file state
that the software is available under either the BSD-2-Clause license OR the
GPL-3.0-or-later license, at the user's choice. When a work is dual-licensed,
the distributor may choose which license to accept and comply with.

**Recommendation:** Select the BSD-2-Clause license for the embedded binary.
Document this choice explicitly in the THIRD-PARTY-NOTICES file with language
such as: "VSEARCH is dual-licensed under BSD-2-Clause and GPL-3.0-or-later.
Lungfish distributes VSEARCH under the BSD-2-Clause license."

**Action required:** Include the BSD-2-Clause license text for VSEARCH in
the notices file. Do NOT reference the GPL-3.0 as the chosen license.

### 2.2 OpenJDK Temurin JRE (GPL-2.0 with Classpath Exception)

**Finding:** LOW RISK -- Classpath Exception covers this usage.

The GNU Classpath Exception (formally: "Linking this library statically or
dynamically with other modules is making a combined work based on this library.
Thus, the terms and conditions of the GNU General Public License cover the whole
combination. As a special exception, the copyright holders of this library give
you permission to link this library with independent modules to produce an
executable, regardless of the license terms of these independent modules...")
explicitly permits:

1. Bundling the JRE as part of an application distribution.
2. Running independent programs (BBTools shell scripts) on the JRE.
3. Distributing the combined package under a non-GPL license.

The Lungfish use case -- embedding the Temurin JRE as a subprocess runtime for
BBTools Java programs -- is the canonical intended use of the Classpath
Exception. BBTools .sh scripts invoke `java` as a separate process; there is
no linking between Lungfish Swift code and the JVM.

**Action required:**
- Include the full GPL-2.0 + Classpath Exception text in the notices file.
- Include the Eclipse Adoptium/Temurin NOTICE file.
- Distribute the JRE unmodified (if modified, the Classpath Exception still
  applies but modifications to the JRE itself must be offered under GPL-2.0).

### 2.3 BBTools / BBMap License (Custom)

**Finding:** MEDIUM RISK -- Permissive in practice but non-standard.

The BBMap/BBTools license (as stated in the BBMap documentation and
SourceForge page) reads approximately: "BBMap is free to use for all
purposes with no restrictions." However, this is NOT an OSI-approved license,
and the precise legal terms have varied across versions.

Key observations:
- Brian Bushnell (author) has consistently stated BBTools is "free for all
  uses" including commercial and redistribution.
- The SourceForge distribution includes a license file stating unrestricted use.
- Some versions reference a DOE/JGI copyright with a BSD-like license.
- There is no copyleft obligation.

**Risk factor:** The lack of a standard, well-understood license text creates
ambiguity. If the license terms were ever disputed, the informal language
could be interpreted differently by different parties.

**Action required:**
- Include the exact BBMap license text from the distributed version (39.13).
- Document the version and download source.
- Consider contacting the author to confirm redistribution rights for embedded
  binary distribution in a commercial-adjacent context.
- Monitor for any license changes in future versions.

### 2.4 cutadapt via PyInstaller (GPL Exception Claim)

**Finding:** LOW RISK -- PyInstaller GPL exception is well-established.

cutadapt itself is MIT-licensed. The concern is that PyInstaller (used to
create the standalone binary) is GPL-2.0-licensed. However, PyInstaller
includes an explicit exception in its license:

> "In addition to the permissions in the GNU General Public License, the
> authors give you unlimited permission to link or embed compiled bootloader
> and related files into combinations with other programs, and to distribute
> those combinations without any restriction coming from the use of those
> files."

This exception specifically covers the bootloader and runtime stub that
PyInstaller embeds in the output binary. The resulting cutadapt binary is
therefore governed by cutadapt's own MIT license, not by PyInstaller's GPL.

**Verification:** This exception has been in the PyInstaller license since
at least version 3.0 (2016) and is documented at:
https://github.com/pyinstaller/pyinstaller/blob/develop/COPYING.txt

**Action required:** Include the cutadapt MIT license in the notices file.
Optionally note that the binary was built with PyInstaller (GPL-2.0 with
bootloader exception).

### 2.5 BWA, SPAdes, FastQC, MultiQC (GPL, NOT Embedded)

**Finding:** NO RISK -- These are not distributed with Lungfish.

These tools are referenced in `BuiltInTools.swift` as tool definitions for
validation purposes, but they are NOT included in the app bundle. They are
either:
- Invoked from the user's system PATH (if installed by the user), or
- Run inside Linux containers via Apple Containerization framework.

**Legal analysis:**

1. **Subprocess invocation does not create a derivative work.** The FSF's own
   GPL FAQ states: "If the program dynamically links plug-ins, and they make
   function calls to each other and share data structures, we believe they
   form a single combined program... However, pipes, sockets, and
   command-line arguments are communication mechanisms normally used between
   two separate programs."
   Lungfish communicates with these tools exclusively via command-line
   arguments, stdin/stdout pipes, and file I/O -- all "arm's length"
   mechanisms.

2. **Container isolation further strengthens separation.** SPAdes runs inside
   a Linux container. The container image is pulled at runtime, not shipped
   with the app. This is analogous to a user installing software separately.

3. **No distribution = no GPL obligation.** GPL obligations are triggered by
   distribution of the GPL-covered work. Since Lungfish does not distribute
   BWA, SPAdes, FastQC, or MultiQC binaries, no GPL obligations attach to
   the Lungfish source code or binary.

**Action required:** None for license compliance. The current approach of
referencing these tools as external dependencies is correct. The About window
already notes these tools and their licenses, which is good practice.

---

## 3. Recommended GitHub License

### Can Lungfish remain MIT-licensed?

**YES.** The repository can and should remain MIT-licensed. Here is the analysis:

### 3.1 The "Mere Aggregation" Principle

Even if GPL-licensed binaries were embedded (which they are not, given the
VSEARCH BSD-2-Clause election and the OpenJDK Classpath Exception), the GPL
itself recognizes "mere aggregation":

> "Mere aggregation of another work not based on the Program with the Program
> (or with a work based on the Program) on a volume of a storage or
> distribution medium does not bring the other work under the scope of this
> License." (GPL-3.0, Section 5)

Lungfish's embedded tools are separate executables invoked via `Process()`
(POSIX fork/exec). They share no address space, no linked symbols, and no
data structures with the Lungfish Swift code. This is textbook "mere
aggregation."

### 3.2 Analysis of Each Integration Pattern

| Pattern | Example | Creates Derivative Work? | GPL Triggered? |
|---------|---------|------------------------|----------------|
| Compiled/linked (SPM) | Swift Argument Parser (Apache 2.0) | Yes (combined work) | No -- Apache 2.0 is compatible |
| Embedded binary, subprocess | SAMtools, SeqKit, fastp | No -- separate program | No |
| Embedded JRE, subprocess | OpenJDK Temurin | No -- Classpath Exception | No |
| External process, user-installed | BWA, SPAdes | No -- not distributed | No |
| Container runtime | SPAdes | No -- not distributed | No |

### 3.3 Recommendation

**Keep the MIT license** for the Lungfish source repository. The MIT license
applies to the Lungfish source code. The embedded third-party binaries retain
their own respective licenses and are documented in a THIRD-PARTY-NOTICES
file (see Section 4).

This is the standard approach used by major applications that bundle
third-party tools (e.g., VS Code bundles Node.js, Electron apps bundle
Chromium, Galaxy bundles bioinformatics tools).

If Lungfish were to statically link against a GPL library (e.g., linking
libhts.a into the Swift binary), that would require relicensing. The current
architecture of subprocess invocation avoids this entirely.

---

## 4. Required Attribution and Notice Files

### 4.1 Legal Requirements by License Type

| License | Attribution Required? | Full License Text Required? | Source Code Offer Required? |
|---------|----------------------|---------------------------|---------------------------|
| MIT | YES -- copyright notice | YES -- in notices file | No |
| BSD-2-Clause | YES -- copyright notice | YES -- in notices file | No |
| Apache 2.0 | YES -- NOTICE file if present | YES -- in notices file | No |
| zlib | YES -- copyright notice | YES -- in notices file | No |
| GPL-2.0+CE (Temurin) | YES | YES -- full GPL + Exception | YES -- source must be obtainable |
| BBMap License | YES (good practice) | YES (include verbatim) | No |

### 4.2 Required THIRD-PARTY-NOTICES File

The application must include a file (accessible to users) containing:

1. **SAMtools / HTSlib / BCFtools** -- MIT license text with copyright
   "Copyright (C) 2012-2024 Genome Research Ltd."

2. **UCSC Genome Browser Tools** -- MIT license text with UCSC copyright.

3. **SeqKit** -- MIT license text with Wei Shen copyright.

4. **fastp** -- MIT license text with OpenGene copyright.

5. **cutadapt** -- MIT license text with Marcel Martin copyright.

6. **BBTools** -- Verbatim BBMap license text from version 39.13.

7. **VSEARCH** -- BSD-2-Clause license text (explicitly chosen from the dual
   license) with Torbjorn Rognes copyright.

8. **pigz** -- zlib license text with Mark Adler copyright.

9. **OpenJDK Temurin** -- Full GPL-2.0 text, Classpath Exception text, and
   Eclipse Adoptium NOTICE. Additionally, a written offer for source code
   (or a URL to the corresponding source) must be provided. The Adoptium
   project provides source at https://github.com/adoptium.

10. **Swift Argument Parser, Collections, Algorithms, System, Async Algorithms**
    -- Apache 2.0 license text (one copy sufficient) plus any NOTICE files
    from Apple's repositories.

11. **Apple Containerization** -- Apache 2.0 license text plus NOTICE if present.

### 4.3 Delivery Mechanism

The notices file should be:
- Included in the app bundle at `Contents/Resources/THIRD-PARTY-NOTICES.txt`
- Accessible from the About window (add a "Licenses" button or link)
- Included in the GitHub repository root as `THIRD-PARTY-NOTICES`
- Included in any binary distribution (DMG, zip)

---

## 5. Risk Assessment

| # | Component | Risk Level | Rationale |
|---|-----------|-----------|-----------|
| 1 | SAMtools 1.22.1 | LOW | MIT -- fully permissive, well-documented license |
| 2 | HTSlib 1.22.1 | LOW | MIT -- same as SAMtools |
| 3 | BCFtools 1.22 | LOW | MIT -- same as SAMtools |
| 4 | UCSC Tools v469 | LOW | MIT -- straightforward |
| 5 | SeqKit 2.9.0 | LOW | MIT -- straightforward |
| 6 | fastp 1.1.0 | LOW | MIT -- straightforward |
| 7 | cutadapt 4.9 | LOW | MIT + PyInstaller exception is well-established |
| 8 | BBTools 39.13 | **MEDIUM** | Custom non-OSI license creates ambiguity; author intent is permissive but terms are informal |
| 9 | VSEARCH 2.29.2 | LOW | Dual-licensed; BSD-2-Clause election eliminates GPL concern |
| 10 | pigz 2.8 | LOW | zlib license -- maximally permissive |
| 11 | OpenJDK Temurin 21 | LOW | Classpath Exception is purpose-built for this exact use case |
| 12 | Swift SPM deps | LOW | All Apache 2.0 -- compatible with everything |
| 13 | BWA (external) | LOW | Not distributed -- no obligation |
| 14 | SPAdes (container) | LOW | Not distributed -- no obligation |
| 15 | FastQC/MultiQC | LOW | Not distributed -- no obligation |

**Overall project risk: LOW**, contingent on completing the action items below.

---

## 6. Recommendations

### PRIORITY 1 -- Required (Legal Compliance)

**R1. Create THIRD-PARTY-NOTICES file.**
A comprehensive notices file with all required license texts must be created
and included in both the repository and the app bundle. This is legally
required by the MIT, BSD-2-Clause, Apache 2.0, zlib, and GPL-2.0+CE licenses.
The project currently has no such file.

**R2. Add GPL-2.0+CE source code offer for OpenJDK.**
The GPL-2.0 (even with Classpath Exception) requires that recipients can
obtain corresponding source code. Include a notice such as:
"The source code for the included OpenJDK runtime is available at
https://github.com/adoptium/temurin-build and
https://github.com/openjdk/jdk21u"

**R3. Explicitly document VSEARCH license election.**
In the notices file and in the `NativeToolRunner.swift` license property,
state that VSEARCH is distributed under the BSD-2-Clause license (not GPL-3.0).
The current code says `"GPL-3.0 or BSD-2-Clause (dual)"` which is accurate
but does not state which license Lungfish has elected. Update to:
`"BSD-2-Clause (dual-licensed; BSD-2-Clause elected)"`

### PRIORITY 2 -- Recommended (Risk Reduction)

**R4. Obtain written confirmation from BBTools author.**
Email Brian Bushnell (DOE Joint Genome Institute) to confirm that embedding
BBTools binaries in a redistributed macOS application is permitted under the
BBMap license. Keep the email correspondence as evidence. This eliminates the
MEDIUM risk rating.

**R5. Add "Open Source Licenses" button to About window.**
The About window (`AboutWindowController.swift`) already lists tools and their
licenses in scrolling credits. Add a button that opens the full
THIRD-PARTY-NOTICES file. This satisfies the "prominent notice" requirement
of several licenses.

**R6. Pin and document exact tool versions.**
The `bundledVersions` dictionary in `NativeToolRunner.swift` already tracks
versions. Ensure these are kept synchronized with actual bundled binaries and
that the THIRD-PARTY-NOTICES file references the same versions.

### PRIORITY 3 -- Best Practice (Future-Proofing)

**R7. Add license metadata to NativeTool enum.**
Extend the `NativeTool` enum to include `licenseURL` and `sourceURL` properties
so that license information is programmatically accessible and can be validated
in tests.

**R8. Create automated license check.**
Add a test that verifies all embedded tools have corresponding entries in the
THIRD-PARTY-NOTICES file. This prevents future tool additions from missing
attribution.

**R9. Document the container tool isolation strategy.**
Add a brief section to the developer documentation explaining why GPL tools
(BWA, SPAdes, FastQC) are invoked via containers or external PATH rather than
embedded, and that this is an intentional license compliance decision.

**R10. Monitor BBTools license evolution.**
The BBMap license is non-standard and could change in future versions. When
upgrading BBTools, re-check the license file in the distribution.

---

## 7. Conclusion

The Lungfish Genome Explorer project has a sound licensing architecture. The
decision to use subprocess invocation for all third-party tools (rather than
static or dynamic linking) avoids GPL copyleft propagation. The dual-license
election for VSEARCH and the Classpath Exception for OpenJDK Temurin are
both legally valid approaches.

The primary compliance gap is the absence of a THIRD-PARTY-NOTICES file.
This is a documentation gap, not an architectural one, and can be resolved
by creating the file described in Section 4.

The repository license should remain **MIT**. No license change is required.

| Item | Status |
|------|--------|
| Can the repo stay MIT? | **YES** |
| Are there GPL contamination risks? | **NO** (with BSD-2-Clause election for VSEARCH) |
| Are there blocking compliance issues? | **NO** (notices file is missing but easily created) |
| Highest-risk component | BBTools (MEDIUM -- non-standard license) |

---

*This report reflects the license landscape as of 2026-03-09. License terms
should be re-verified when upgrading any dependency.*
