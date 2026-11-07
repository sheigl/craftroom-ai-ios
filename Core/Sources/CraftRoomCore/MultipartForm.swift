import Foundation

/// `multipart/form-data` encoder for `POST /generate`
/// (`photo` file, `aspect` text, optional `seed` text).
///
/// Hand-rolled because the app has no HTTP library and the encoding is small,
/// deterministic and unit-tested: CRLF line endings, a boundary that cannot
/// collide with the payload, and the closing `--boundary--` terminator the
/// server (Starlette) requires.
public enum MultipartForm {
    public struct Part: Equatable {
        public var name: String
        public var filename: String?
        public var contentType: String?
        public var data: Data

        public init(name: String, data: Data,
                    filename: String? = nil, contentType: String? = nil) {
            self.name = name
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }

        public init(name: String, value: String) {
            self.init(name: name, data: Data(value.utf8))
        }
    }

    /// A boundary derived from a UUID and a timestamp: unique per request, no
    /// dashes at the end (they are added by the encoder) and no characters that
    /// need quoting.
    public static func boundary() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "craftroom-\(raw.prefix(24))"
    }

    public static func body(_ parts: [Part], boundary: String) -> Data {
        var out = Data()
        for part in parts {
            out.append("--\(boundary)\r\n")
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename {
                disposition += "; filename=\"\(filename)\""
            }
            out.append(disposition + "\r\n")
            if let contentType = part.contentType {
                out.append("Content-Type: \(contentType)\r\n")
            }
            out.append("\r\n")
            out.append(part.data)
            out.append("\r\n")
        }
        out.append("--\(boundary)--\r\n")
        return out
    }

    /// The exact body of `POST /generate` for one input.
    public static func photoBody(_ input: GenerationInput, boundary: String) -> Data {
        var parts: [Part] = [
            Part(name: "photo", data: input.photo,
                 filename: input.filename, contentType: input.contentType),
            Part(name: "aspect", value: input.aspect),
        ]
        if let seed = input.seed {
            parts.append(Part(name: "seed", value: String(seed)))
        }
        return body(parts, boundary: boundary)
    }

    /// The `Content-Type` header value that carries the boundary.
    public static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: Array(string.utf8))
    }
}
