import XCTest
@testable import Spool

/// Guards the AdmitStub empty-default fix: the component used to default
/// `handle: "@yurui"` / `stubNo: "#0127"`, leaking demo data onto real users'
/// on-screen stub cards. The defaults are now empty and the top-left chrome
/// line degrades gracefully — `admitLine` drops the "· " separator (and the
/// number) when no sequence number is supplied. These pin that pure seam so
/// the dangling "ADMIT ONE · " can never render.
final class AdmitStubLabelTests: XCTestCase {

    func testAdmitLineWithNumber() {
        XCTAssertEqual(AdmitStub.admitLine(stubNo: "#0042"), "ADMIT ONE · #0042")
        XCTAssertEqual(AdmitStub.admitLine(stubNo: "#5"), "ADMIT ONE · #5")
    }

    func testAdmitLineEmptyOmitsSeparator() {
        // Empty number → plain "ADMIT ONE", never a trailing "· " with nothing
        // after it.
        XCTAssertEqual(AdmitStub.admitLine(stubNo: ""), "ADMIT ONE")
    }

    func testDefaultInitCarriesNoDemoData() {
        // The shipped default must be empty so no fake "@yurui" / "#0127" can
        // render on a real user's card. (Callers pass real values.)
        let stub = AdmitStub(movie: SpoolData.subject)
        XCTAssertEqual(stub.handle, "")
        XCTAssertNotEqual(stub.handle, "@yurui")
        XCTAssertEqual(stub.stubNo, "")
        XCTAssertNotEqual(stub.stubNo, "#0127")
        // And an empty default number degrades to the plain chrome line.
        XCTAssertEqual(AdmitStub.admitLine(stubNo: stub.stubNo), "ADMIT ONE")
    }
}
