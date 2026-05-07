import Testing
import Foundation
@testable import LungfishWorkflow

@Suite("IVarTSVRow")
struct IVarTSVRowTests {
    private static let header = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"

    @Test("parses a SNP row")
    func parsesSNP() throws {
        let line = "MN908947.3\t241\tC\tT\t0\t0\t0\t1950\t935\t37\t1\t1950\t0\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.region == "MN908947.3")
        #expect(row.pos == 241)
        #expect(row.ref == "C")
        #expect(row.alt == "T")
        #expect(row.altFreq == 1.0)
        #expect(row.totalDP == 1950)
        #expect(row.pass == true)
        #expect(row.kind == .snp)
    }

    @Test("parses an insertion encoded with +")
    func parsesInsertion() throws {
        let line = "MN908947.3\t100\tA\t+TG\t10\t5\t30\t40\t20\t37\t0.8\t50\t0.001\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.kind == .insertion(insertedBases: "TG"))
        #expect(row.ref == "A")
        #expect(row.alt == "+TG")
    }

    @Test("parses a deletion encoded with -")
    func parsesDeletion() throws {
        let line = "MN908947.3\t200\tA\t-CG\t40\t20\t37\t10\t5\t30\t0.2\t50\t0.001\tTRUE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.kind == .deletion(deletedBases: "CG"))
    }

    @Test("treats PASS=FALSE as false")
    func parsesPassFalse() throws {
        let line = "MN908947.3\t44\tC\tT\t75\t75\t38\t4\t2\t38\t0.05\t79\t0.06\tFALSE\tNA\tNA\tNA\tNA\tNA\tNA"
        let row = try #require(IVarTSVRow.parse(line: line, header: Self.header))
        #expect(row.pass == false)
    }

    @Test("returns nil for malformed line")
    func rejectsMalformed() {
        let row = IVarTSVRow.parse(line: "only one field", header: Self.header)
        #expect(row == nil)
    }
}
