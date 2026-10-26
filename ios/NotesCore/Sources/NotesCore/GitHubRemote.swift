import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RepositoryAddress: Codable, Equatable, Sendable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

public final class GitHubRemote: GitRemote {
    private let address: RepositoryAddress
    private let token: String
    private let session: URLSession
    private let apiUrl = URL(string: "https://api.github.com")!
    private let readmeContent = "# VAD/OS Notes\n\nSynced by VAD/OS Notes. Do not edit page files by hand.\n"

    public init(address: RepositoryAddress, token: String, session: URLSession = .shared) {
        self.address = address
        self.token = token
        self.session = session
    }

    public func headCommit(branch: String) async throws -> String? {
        do {
            let reference: ReferenceResponse = try await request("GET", "git/ref/heads/\(branch)")
            return reference.object.sha
        } catch RemoteError.notFound {
            return nil
        } catch RemoteError.server(let status, _) where status == 409 {
            return nil
        }
    }

    public func initialize(branch: String) async throws -> String {
        let repository: RepositoryResponse = try await request("GET", "")
        let defaultBranch = repository.defaultBranch
        if let defaultHead = try await headCommit(branch: defaultBranch) {
            let created: ReferenceResponse = try await request("POST", "git/refs", body: CreateReferenceRequest(ref: "refs/heads/\(branch)", sha: defaultHead))
            return created.object.sha
        }
        let content = Data(readmeContent.utf8).base64EncodedString()
        let created: ContentsResponse = try await request("PUT", "contents/README.md", body: CreateContentsRequest(message: "Start VAD/OS Notes", content: content, branch: defaultBranch))
        if branch == defaultBranch {
            return created.commit.sha
        }
        let reference: ReferenceResponse = try await request("POST", "git/refs", body: CreateReferenceRequest(ref: "refs/heads/\(branch)", sha: created.commit.sha))
        return reference.object.sha
    }

    public func files(commit: String) async throws -> [String: String] {
        let commitResponse: CommitResponse = try await request("GET", "git/commits/\(commit)")
        let tree: TreeResponse = try await request("GET", "git/trees/\(commitResponse.tree.sha)?recursive=1")
        if tree.truncated == true {
            throw RemoteError.server(status: 0, message: "Repository tree is too large to list in one request")
        }
        var files: [String: String] = [:]
        for entry in tree.tree where entry.type == "blob" {
            files[entry.path] = entry.sha
        }
        return files
    }

    public func blob(sha: String) async throws -> Data {
        let blob: BlobResponse = try await request("GET", "git/blobs/\(sha)")
        guard blob.encoding == "base64", let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters) else {
            throw RemoteError.server(status: 0, message: "Blob \(sha) is not base64")
        }
        return data
    }

    public func commit(files: [String: Data], parent: String, message: String) async throws -> CommitResult {
        var blobs: [String: String] = [:]
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let created: ShaResponse = try await request("POST", "git/blobs", body: CreateBlobRequest(content: data.base64EncodedString(), encoding: "base64"))
            blobs[path] = created.sha
        }
        let parentCommit: CommitResponse = try await request("GET", "git/commits/\(parent)")
        let entries = blobs.sorted(by: { $0.key < $1.key }).map { TreeEntryRequest(path: $0.key, mode: "100644", type: "blob", sha: $0.value) }
        let tree: ShaResponse = try await request("POST", "git/trees", body: CreateTreeRequest(baseTree: parentCommit.tree.sha, tree: entries))
        let commit: ShaResponse = try await request("POST", "git/commits", body: CreateCommitRequest(message: message, tree: tree.sha, parents: [parent]))
        return CommitResult(sha: commit.sha, blobs: blobs)
    }

    public func moveBranch(_ branch: String, to commit: String) async throws {
        do {
            let _: ReferenceResponse = try await request("PATCH", "git/refs/heads/\(branch)", body: UpdateReferenceRequest(sha: commit, force: false))
        } catch RemoteError.server(let status, _) where status == 409 || status == 422 {
            throw RemoteError.rejected
        }
    }

    private func request<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await request(method, path, bodyData: nil)
    }

    private func request<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try await request(method, path, bodyData: try encoder.encode(body))
    }

    private func request<Response: Decodable>(_ method: String, _ path: String, bodyData: Data?) async throws -> Response {
        let base = "\(apiUrl.absoluteString)/repos/\(address.owner)/\(address.name)"
        guard let url = URL(string: path.isEmpty ? base : "\(base)/\(path)") else {
            throw RemoteError.transport("Bad url for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.transport("No HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw RemoteError.unauthorized
        case 404:
            throw RemoteError.notFound
        default:
            throw RemoteError.server(status: http.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw RemoteError.server(status: http.statusCode, message: "Unreadable response: \(error)")
        }
    }
}

struct ShaResponse: Decodable {
    let sha: String
}

struct ReferenceResponse: Decodable {
    let object: ShaResponse
}

struct RepositoryResponse: Decodable {
    let defaultBranch: String
}

struct ContentsResponse: Decodable {
    let commit: ShaResponse
}

struct CommitResponse: Decodable {
    let sha: String
    let tree: ShaResponse
}

struct TreeEntryResponse: Decodable {
    let path: String
    let type: String
    let sha: String
}

struct TreeResponse: Decodable {
    let tree: [TreeEntryResponse]
    let truncated: Bool?
}

struct BlobResponse: Decodable {
    let content: String
    let encoding: String
}

struct CreateReferenceRequest: Encodable {
    let ref: String
    let sha: String
}

struct UpdateReferenceRequest: Encodable {
    let sha: String
    let force: Bool
}

struct CreateContentsRequest: Encodable {
    let message: String
    let content: String
    let branch: String
}

struct CreateBlobRequest: Encodable {
    let content: String
    let encoding: String
}

struct TreeEntryRequest: Encodable {
    let path: String
    let mode: String
    let type: String
    let sha: String
}

struct CreateTreeRequest: Encodable {
    let baseTree: String
    let tree: [TreeEntryRequest]
}

struct CreateCommitRequest: Encodable {
    let message: String
    let tree: String
    let parents: [String]
}
