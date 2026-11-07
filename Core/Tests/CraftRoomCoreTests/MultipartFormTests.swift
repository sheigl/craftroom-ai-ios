import XCTest
@testable import CraftRoomCore

/// `multipart/form-data` for `POST /generate`, checked byte for byte because a
/// wrong CRLF or a missing terminator is a 422 from the server, not a hint.
final class MultipartFormTests: XCTestCase {
    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    func testBodyUsesCRLFAndTerminates() {
        let boundary = "craftroom-test"
        let body = MultipartForm.body(
            [MultipartForm.Part(name: "aspect", value: "auto")],
            boundary: boundary)
        let expected = "--craftroom-test\r\n"
            + "Content-Disposition: form-data; name=\"aspect\"\r\n"
            + "\r\n"
            + "auto\r\n"
            + "--craftroom-test--\r\n"
        XCTAssertEqual(body, Data(expected.utf8))
    }

    func testFilePartCarriesFilenameAndContentType() {
        // A JPEG magic prefix: bytes are compared, not text (the payload is not
        // valid UTF-8, so a lossy string comparison would hide a bug).
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let body = MultipartForm.body(
            [MultipartForm.Part(name: "photo", data: photo,
                                filename: "photo.jpg", contentType: "image/jpeg")],
            boundary: "B")
        var expected = Data("--B\r\n".utf8)
        expected += Data("Content-Disposition: form-data; name=\"photo\"; "
            .utf8)
        expected += Data("filename=\"photo.jpg\"\r\n".utf8)
        expected += Data("Content-Type: image/jpeg\r\n\r\n".utf8)
        expected += photo
        expected += Data("\r\n--B--\r\n".utf8)
        XCTAssertEqual(body, expected)
        XCTAssertEqual(boundaryCount(body, boundary: "B"), 2)
    }

    private func boundaryCount(_ body: Data, boundary: String) -> Int {
        let needle = Data(("--" + boundary).utf8)
        var count = 0
        var index = body.startIndex
        while let found = body.range(of: needle, in: index..<body.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    func testPhotoBodyContainsEveryServerFieldInOrder() {
        let input = GenerationInput(photo: Data([0x01, 0x02, 0x03]),
                                    aspect: "landscape", seed: 42)
        let body = MultipartForm.photoBody(input, boundary: "X")
        let string = text(body)
        let photoAt = string.range(of: "name=\"photo\"")?.lowerBound
        let aspectAt = string.range(of: "name=\"aspect\"")?.lowerBound
        let seedAt = string.range(of: "name=\"seed\"")?.lowerBound
        XCTAssertNotNil(photoAt)
        XCTAssertNotNil(aspectAt)
        XCTAssertNotNil(seedAt)
        if let photoAt, let aspectAt, let seedAt {
            XCTAssertTrue(photoAt < aspectAt)
            XCTAssertTrue(aspectAt < seedAt)
        }
        XCTAssertTrue(string.contains("filename=\"photo.jpg\""))
        XCTAssertTrue(string.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(string.hasSuffix("--X--\r\n"))
    }

    func testSeedIsOmittedWhenNotRequested() {
        let input = GenerationInput(photo: Data([0x00]), aspect: "auto", seed: nil)
        let body = MultipartForm.photoBody(input, boundary: "Y")
        XCTAssertFalse(text(body).contains("name=\"seed\""))
        XCTAssertTrue(text(body).contains("name=\"aspect\""))
    }

    func testBoundaryIsUniqueAndHeaderMatchesIt() {
        let a = MultipartForm.boundary()
        let b = MultipartForm.boundary()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.hasPrefix("--"))
        XCTAssertFalse(a.hasSuffix("-"))
        XCTAssertEqual(MultipartForm.contentType(boundary: a),
                       "multipart/form-data; boundary=\(a)")
        XCTAssertTrue(text(MultipartForm.body([], boundary: a)).hasPrefix("--\(a)--"))
    }
}
