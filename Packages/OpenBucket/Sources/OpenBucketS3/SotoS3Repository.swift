import AsyncHTTPClient
import Darwin
import Foundation
import OpenBucketCore
import SotoCore
import SotoS3
import os

public struct SotoS3Repository: S3Repository {
  private let httpClient: any AWSHTTPClient

  public init() {
    self.init(httpClient: HTTPClient.shared)
  }

  init(httpClient: any AWSHTTPClient) {
    self.httpClient = httpClient
  }

  public func listBuckets(profile: ConnectionProfile, credentials: S3Credentials) async throws -> [String] {
    try await withService(profile: profile, credentials: credentials, bucket: nil) { service in
      let output = try await service.listBuckets()
      return output.buckets?.compactMap(\.name) ?? []
    }
  }

  public func listObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) async throws -> ObjectPage {
    try await listPage(
      profile: profile, credentials: credentials, bucket: bucket, prefix: prefix,
      continuationToken: continuationToken, delimiter: "/", maxKeys: 500)
  }

  public func listAllObjects(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?
  ) async throws -> ObjectPage {
    try await listPage(
      profile: profile, credentials: credentials, bucket: bucket, prefix: prefix,
      continuationToken: continuationToken, delimiter: nil, maxKeys: 1000)
  }

  private func listPage(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    continuationToken: String?,
    delimiter: String?,
    maxKeys: Int
  ) async throws -> ObjectPage {
    try await withService(profile: profile, credentials: credentials, bucket: bucket) { service in
      let request = S3.ListObjectsV2Request(
        bucket: bucket,
        continuationToken: continuationToken,
        delimiter: delimiter,
        encodingType: .url,
        maxKeys: maxKeys,
        prefix: prefix
      )
      let output = try await service.listObjectsV2(request)
      let isURLEncoded = output.encodingType == .url
      let prefixes = try Self.decodePrefixes(output.commonPrefixes, isURLEncoded: isURLEncoded)
      let objects = try (output.contents ?? []).compactMap { object -> ObjectSummary? in
        guard let key = object.key else { return nil }
        return ObjectSummary(
          key: try Self.decodeKey(key, isURLEncoded: isURLEncoded),
          size: object.size ?? 0,
          lastModified: object.lastModified,
          eTag: object.eTag,
          storageClass: object.storageClass?.rawValue
        )
      }
      let nextToken = try Self.nextMarker(output.isTruncated, output.nextContinuationToken)
      return ObjectPage(prefixes: prefixes, objects: objects, nextToken: nextToken)
    }
  }

  public func listObjectVersions(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    prefix: String,
    delimiter: String?,
    keyMarker: String?,
    versionIDMarker: String?
  ) async throws -> VersionPage {
    try await withService(profile: profile, credentials: credentials, bucket: bucket) { service in
      let request = S3.ListObjectVersionsRequest(
        bucket: bucket, delimiter: delimiter, encodingType: .url, keyMarker: keyMarker, prefix: prefix,
        versionIdMarker: versionIDMarker)
      let output: VersionListing = try await service.client.execute(
        operation: "ListObjectVersions", path: "/{Bucket}?versions", httpMethod: .GET,
        serviceConfig: service.config, input: request)
      let isURLEncoded = output.encodingType == .url
      let prefixes = try Self.decodePrefixes(output.commonPrefixes, isURLEncoded: isURLEncoded)
      func rows(_ entries: [VersionListing.Entry]?, markers: Bool) throws -> [ObjectVersion] {
        try (entries ?? []).compactMap { entry in
          guard let key = entry.key else { return nil }
          return ObjectVersion(
            key: try Self.decodeKey(key, isURLEncoded: isURLEncoded), versionID: entry.versionId ?? "null",
            isLatest: entry.isLatest ?? false, isDeleteMarker: markers, lastModified: entry.lastModified,
            size: entry.size ?? 0, eTag: entry.eTag, storageClass: entry.storageClass)
        }
      }
      let markers = try rows(output.deleteMarkers, markers: true)
      let versions = try rows(output.versions, markers: false)
      // S3 order: key bytes, then newest first; on equal timestamps the latest entry wins.
      let merged = (versions + markers).sorted { lhs, rhs in
        if !lhs.key.utf8.elementsEqual(rhs.key.utf8) {
          return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        let (left, right) = (lhs.lastModified ?? .distantPast, rhs.lastModified ?? .distantPast)
        return left != right ? left > right : lhs.isLatest && !rhs.isLatest
      }
      let nextKey = try Self.nextMarker(output.isTruncated, output.nextKeyMarker)
        .map { try Self.decodeKey($0, isURLEncoded: isURLEncoded) }
      return VersionPage(
        prefixes: prefixes, versions: merged, nextKeyMarker: nextKey,
        nextVersionIDMarker: nextKey == nil ? nil : output.nextVersionIdMarker)
    }
  }

  public func objectDetails(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?
  ) async throws -> ObjectDetails {
    try await withService(profile: profile, credentials: credentials, bucket: bucket) { service in
      let head: S3.HeadObjectOutput
      do {
        head = try await service.headObject(bucket: bucket, key: key, versionId: versionID)
      } catch {
        // HEAD responses have no body, so a deleted key or version arrives as a bare 404 ("NotFound").
        let failure = S3ErrorMapper.map(error)
        guard failure.category == .notFound else { throw error }
        throw S3Failure(
          category: .notFound, message: S3ErrorMapper.objectMissing, technicalDetail: failure.technicalDetail)
      }
      // Tagging is often denied or unimplemented; that must not hide the HEAD result.
      let tagging = try? await service.getObjectTagging(bucket: bucket, key: key, versionId: versionID)
      try Task.checkCancellation()
      return ObjectDetails(
        contentType: head.contentType, cacheControl: head.cacheControl, contentEncoding: head.contentEncoding,
        contentDisposition: head.contentDisposition, contentLanguage: head.contentLanguage,
        contentLength: head.contentLength, eTag: head.eTag, lastModified: head.lastModified,
        storageClass: head.storageClass?.rawValue, serverSideEncryption: head.serverSideEncryption?.rawValue,
        kmsKeyID: head.ssekmsKeyId, versionID: head.versionId, restore: head.restore,
        replicationStatus: head.replicationStatus?.rawValue, objectLockMode: head.objectLockMode?.rawValue,
        objectLockRetainUntil: head.objectLockRetainUntilDate,
        legalHold: head.objectLockLegalHoldStatus?.rawValue,
        metadata: Dictionary(
          (head.metadata ?? [:]).map { ($0.key.lowercased(), $0.value) },
          uniquingKeysWith: { first, _ in first }),
        tags: tagging.map {
          Dictionary($0.tagSet.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
      )
    }
  }

  public func readObjectBytes(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    range: Range<Int64>
  ) async throws -> Data {
    guard !range.isEmpty else { return Data() }
    return try await withService(profile: profile, credentials: credentials, bucket: bucket) { service in
      let output: S3.GetObjectOutput
      do {
        output = try await service.getObject(
          bucket: bucket, key: key, range: "bytes=\(range.lowerBound)-\(range.upperBound - 1)")
      } catch let error as any AWSErrorType
        where error.errorCode == "InvalidRange" || error.context?.responseCode.code == 416
      {
        return Data()  // the range starts past the end of the object
      }
      // A server that ignores Range sends the whole object from byte 0.
      var skip = output.contentRange == nil ? Int(range.lowerBound) : 0
      var data = Data()
      if !output.body.isEmpty {
        for try await chunk in output.body {
          var bytes = chunk.readableBytesView.dropFirst(skip)
          skip -= chunk.readableBytes - bytes.count
          bytes = bytes.prefix(range.count - data.count)
          data.append(contentsOf: bytes)
          if data.count == range.count { break }
        }
      }
      return data
    }
  }

  public func presignedURL(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    expiresIn: Duration,
    downloadFileName: String?
  ) async throws -> URL {
    guard expiresIn >= .seconds(1), expiresIn <= .seconds(7 * 24 * 60 * 60) else {
      throw S3Failure(category: .unknown, message: "Links must expire between 1 second and 7 days.")
    }
    return try await withService(profile: profile, credentials: credentials, bucket: bucket) { service in
      try await service.signURL(
        url: Self.objectURL(
          profile: profile, bucket: bucket, key: key, versionID: versionID,
          downloadFileName: downloadFileName),
        httpMethod: .GET, expires: .seconds(expiresIn.components.seconds))
    }
  }

  /// The object URL Soto's S3 middleware would request for this profile; the signer re-encodes the path.
  /// `downloadFileName` adds a `response-content-disposition` override, which the presigned URL signs.
  static func objectURL(
    profile: ConnectionProfile, bucket: String, key: String, versionID: String?, downloadFileName: String?
  ) -> URL {
    var components = URLComponents(url: profile.endpoint.url, resolvingAgainstBaseURL: false)!
    let host = components.host ?? ""
    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    let isAmazon = host.hasSuffix(Region(rawValue: profile.region).partition.dnsSuffix)
    if isAmazon || profile.addressingStyle == .virtualHost, !bucket.contains(".") {
      if host.split(separator: ".").first.map(String.init) != bucket { components.host = "\(bucket).\(host)" }
      components.percentEncodedPath = "/" + encodedKey
    } else {
      var path = components.percentEncodedPath
      if path.hasSuffix("/") { path.removeLast() }
      components.percentEncodedPath = "\(path)/\(bucket)/\(encodedKey)"
    }
    let query = [
      URLQueryItem(name: "versionId", value: versionID),
      URLQueryItem(name: "response-content-disposition", value: downloadFileName.map(contentDisposition)),
    ].filter { $0.value != nil }
    if !query.isEmpty {
      // Strictly encoded so no value character can split the query; the signer decodes and re-encodes.
      components.percentEncodedQueryItems = query.map {
        URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
      }
    }
    return components.url!
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// `attachment` with an ASCII `filename` fallback (non-ASCII, controls, `"` and `\` become "_") and the
  /// exact name as an RFC 5987 `filename*`.
  static func contentDisposition(fileName: String) -> String {
    let fallback = String(
      String.UnicodeScalarView(
        fileName.unicodeScalars.map {
          (0x20..<0x7F).contains($0.value) && $0 != "\"" && $0 != "\\" ? $0 : "_"
        }))
    let attrChar = unreserved.union(CharacterSet(charactersIn: "!#$&+^`|"))
    let encoded = fileName.addingPercentEncoding(withAllowedCharacters: attrChar) ?? fallback
    return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
  }

  public func resolveAWSProfile(_ name: String) async throws -> S3Credentials {
    // SSO and login first: they fail fast without network for profiles that don't use them.
    let client = AWSClient(
      credentialProvider: .selector(
        .sso(profileName: name), .login(profileName: name), .configFile(profile: name)),
      httpClient: httpClient
    )
    do {
      let credential = try await client.getCredential()
      try? await client.shutdown()
      return S3Credentials(
        accessKeyID: credential.accessKeyId, secretAccessKey: credential.secretAccessKey,
        sessionToken: credential.sessionToken, expiration: (credential as? any ExpiringCredential)?.expiration
      )
    } catch {
      try? await client.shutdown()
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw S3Failure(
        category: .missingCredentials,
        message: "AWS profile ‘\(name)’ couldn't be used. For IAM Identity Center, run "
          + "`aws sso login --profile \(name)`.",
        technicalDetail: "SDK error: \(type(of: error))")
    }
  }

  public func downloadObject(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    versionID: String?,
    to destination: URL,
    maximumBytes: Int64,
    progress: @escaping @Sendable (_ bytesReceived: Int64) -> Void
  ) async throws {
    let timeout: SotoCore.TimeAmount = maximumBytes == .max ? .seconds(3600) : .seconds(120)
    let tooLarge = S3Failure(category: .unknown, message: "This object is too large to preview.")
    try await withService(profile: profile, credentials: credentials, bucket: bucket, timeout: timeout) {
      service in
      let output = try await service.getObject(bucket: bucket, key: key, versionId: versionID)
      if let length = output.contentLength, length > maximumBytes { throw tooLarge }
      // The OS cleans the replacement directory up even if the app quits mid-download.
      let fileManager = FileManager.default
      let scratch = try? fileManager.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
      let staging = (scratch ?? destination.deletingLastPathComponent())
        .appendingPathComponent(".openbucket-\(UUID().uuidString).download")
      defer { try? fileManager.removeItem(at: scratch ?? staging) }
      try Self.fileOperation {
        guard fileManager.createFile(atPath: staging.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
      let handle = try Self.fileOperation { try FileHandle(forWritingTo: staging) }
      defer { try? handle.close() }
      var byteCount: Int64 = 0
      if !output.body.isEmpty {
        for try await chunk in output.body {
          try Task.checkCancellation()
          guard chunk.readableBytes <= maximumBytes - byteCount else { throw tooLarge }
          try Self.fileOperation { try handle.write(contentsOf: Data(chunk.readableBytesView)) }
          byteCount += Int64(chunk.readableBytes)
          progress(byteCount)
        }
      }
      try Self.fileOperation { try handle.close() }
      try Task.checkCancellation()
      try Self.fileOperation {
        guard Darwin.rename(staging.path, destination.path) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
      }
    }
  }

  public func bucketVersioning(profile: ConnectionProfile, credentials: S3Credentials, bucket: String)
    async throws -> BucketVersioning
  {
    try await withService(profile: profile, credentials: credentials, bucket: bucket) { service in
      let status = try await service.getBucketVersioning(bucket: bucket).status
      return switch status {
      case .enabled: BucketVersioning.enabled
      case .suspended: .suspended
      default: .disabled
      }
    }
  }

  static let singlePutLimit: Int64 = 16 * 1024 * 1024
  static let singleCopyLimit: Int64 = 5 * 1024 * 1024 * 1024

  /// At least `minimum`, grown so the object fits in S3's 10 000 parts.
  static func partSize(for size: Int64, minimum: Int64) -> Int64 {
    max(minimum, (size + 9_999) / 10_000)
  }

  public func uploadFile(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    key: String,
    from source: URL,
    headers: ObjectHeaders,
    progress: @escaping @Sendable (_ bytesSent: Int64) -> Void
  ) async throws {
    let (handle, size) = try Self.fileOperation(reading: true) {
      let handle = try FileHandle(forReadingFrom: source)
      return (handle, Int64(try handle.seekToEnd()))
    }
    defer { try? handle.close() }
    try Self.fileOperation(reading: true) { try handle.seek(toOffset: 0) }
    let sent = OSAllocatedUnfairLock(initialState: Int64(0))
    // Parts read the handle in order, straight into the request, so progress follows what was sent.
    @Sendable func body(_ length: Int64) -> AWSHTTPBody {
      let chunks = FileChunks(handle: handle, length: length) { count in
        progress(
          sent.withLock {
            $0 += Int64(count)
            return $0
          })
      }
      return AWSHTTPBody(asyncSequence: chunks, length: Int(length))
    }
    try await withService(
      profile: profile, credentials: credentials, bucket: bucket, timeout: .seconds(3600), writing: true
    ) { service in
      guard size > Self.singlePutLimit else {
        _ = try await service.putObject(
          S3.PutObjectRequest(
            body: body(size), bucket: bucket, cacheControl: headers.cacheControl,
            contentDisposition: headers.contentDisposition, contentEncoding: headers.contentEncoding,
            contentLanguage: headers.contentLanguage, contentType: headers.contentType, key: key,
            metadata: headers.metadata))
        return
      }
      let upload = try await service.createMultipartUpload(
        S3.CreateMultipartUploadRequest(
          bucket: bucket, cacheControl: headers.cacheControl, contentDisposition: headers.contentDisposition,
          contentEncoding: headers.contentEncoding, contentLanguage: headers.contentLanguage,
          contentType: headers.contentType, key: key, metadata: headers.metadata))
      let partSize = Self.partSize(for: size, minimum: Self.singlePutLimit)
      try await Self.completeMultipart(service, upload, bucket: bucket, key: key) { uploadID, number in
        let offset = Int64(number - 1) * partSize
        guard offset < size else { return nil }
        let output = try await service.uploadPart(
          S3.UploadPartRequest(
            body: body(min(partSize, size - offset)), bucket: bucket, key: key, partNumber: number,
            uploadId: uploadID))
        return output.eTag
      }
    }
  }

  public func putEmptyObject(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String
  ) async throws {
    try await withService(profile: profile, credentials: credentials, bucket: bucket, writing: true) {
      service in
      _ = try await service.putObject(body: AWSHTTPBody(), bucket: bucket, key: key)
    }
  }

  public func copyObject(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String,
    sourceKey: String,
    sourceVersionID: String?,
    size: Int64,
    destinationKey: String,
    headers: ObjectHeaders?
  ) async throws {
    let source = Self.copySource(bucket: bucket, key: sourceKey, versionID: sourceVersionID)
    // UploadPartCopy carries neither metadata nor tags, and services reject an unchanged copy onto its own key
    // (even from an older version, which is how restore works), so both send the source's headers explicitly.
    let details =
      size > Self.singleCopyLimit || (headers == nil && sourceKey == destinationKey)
      ? try await objectDetails(
        profile: profile, credentials: credentials, bucket: bucket, key: sourceKey, versionID: sourceVersionID
      )
      : nil
    let headers = headers ?? details.map(ObjectHeaders.init)
    guard size > Self.singleCopyLimit else {
      try await withService(
        profile: profile, credentials: credentials, bucket: bucket, timeout: .seconds(3600), writing: true
      ) { service in
        _ = try await service.copyObject(
          S3.CopyObjectRequest(
            bucket: bucket, cacheControl: headers?.cacheControl,
            contentDisposition: headers?.contentDisposition,
            contentEncoding: headers?.contentEncoding, contentLanguage: headers?.contentLanguage,
            contentType: headers?.contentType, copySource: source, key: destinationKey,
            metadata: headers?.metadata, metadataDirective: headers == nil ? .copy : .replace))
      }
      return
    }
    let tagging = details?.tags.flatMap { tags -> String? in
      tags.isEmpty
        ? nil
        : tags.sorted { $0.key < $1.key }.map { "\(Self.formEncoded($0))=\(Self.formEncoded($1))" }
          .joined(separator: "&")
    }
    try await withService(
      profile: profile, credentials: credentials, bucket: bucket, timeout: .seconds(3600), writing: true
    ) { service in
      let upload = try await service.createMultipartUpload(
        S3.CreateMultipartUploadRequest(
          bucket: bucket, cacheControl: headers?.cacheControl,
          contentDisposition: headers?.contentDisposition,
          contentEncoding: headers?.contentEncoding, contentLanguage: headers?.contentLanguage,
          contentType: headers?.contentType, key: destinationKey, metadata: headers?.metadata,
          tagging: tagging))
      // Server-side parts are cheap to request, so they are large to keep the request count low.
      let partSize = Self.partSize(for: size, minimum: 512 * 1024 * 1024)
      try await Self.completeMultipart(service, upload, bucket: bucket, key: destinationKey) {
        uploadID, number in
        let offset = Int64(number - 1) * partSize
        guard offset < size else { return nil }
        let output = try await service.uploadPartCopy(
          S3.UploadPartCopyRequest(
            bucket: bucket, copySource: source,
            copySourceRange: "bytes=\(offset)-\(min(offset + partSize, size) - 1)", key: destinationKey,
            partNumber: number, uploadId: uploadID))
        return output.copyPartResult.eTag
      }
    }
  }

  public func deleteObjects(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, keys: [String]
  ) async throws -> [DeleteFailure] {
    try await withService(
      profile: profile, credentials: credentials, bucket: bucket, timeout: .seconds(120), writing: true
    ) { service in
      var failures: [DeleteFailure] = []
      for start in stride(from: 0, to: keys.count, by: 1000) {
        let batch = keys[start..<min(start + 1000, keys.count)]
        // Soto adds the Content-MD5 header S3 requires for DeleteObjects.
        let output = try await service.deleteObjects(
          bucket: bucket, delete: S3.Delete(objects: batch.map { S3.ObjectIdentifier(key: $0) }, quiet: true))
        failures += (output.errors ?? []).map { error in
          DeleteFailure(
            key: error.key ?? "",
            message: S3ErrorMapper.serviceFailure(code: error.code, status: nil, writing: true).message)
        }
      }
      return failures
    }
  }

  public func putObjectTags(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String,
    tags: [String: String]
  ) async throws {
    try await withService(profile: profile, credentials: credentials, bucket: bucket, writing: true) {
      service in
      // An empty TagSet is malformed XML to some providers; deleting the tagging means the same.
      guard !tags.isEmpty else {
        _ = try await service.deleteObjectTagging(bucket: bucket, key: key)
        return
      }
      let tagSet = tags.sorted { $0.key < $1.key }.map { S3.Tag(key: $0.key, value: $0.value) }
      _ = try await service.putObjectTagging(bucket: bucket, key: key, tagging: S3.Tagging(tagSet: tagSet))
    }
  }

  /// Sends parts numbered from 1 until `part` returns nil, then completes the upload. Any failure,
  /// cancellation included, aborts it so the parts don't linger (and bill) on the server.
  private static func completeMultipart(
    _ service: S3, _ upload: S3.CreateMultipartUploadOutput, bucket: String, key: String,
    part: (_ uploadID: String, _ number: Int) async throws -> String??
  ) async throws {
    guard let uploadID = upload.uploadId else {
      throw S3Failure(category: .service, message: "S3 started an upload without an upload ID.")
    }
    do {
      var parts: [S3.CompletedPart] = []
      while let eTag = try await part(uploadID, parts.count + 1) {
        try Task.checkCancellation()
        parts.append(S3.CompletedPart(eTag: eTag, partNumber: parts.count + 1))
      }
      _ = try await service.completeMultipartUpload(
        S3.CompleteMultipartUploadRequest(
          bucket: bucket, key: key, multipartUpload: S3.CompletedMultipartUpload(parts: parts),
          uploadId: uploadID))
    } catch {
      // A new task, because requests from a cancelled one are cancelled before they're sent.
      let abort = S3.AbortMultipartUploadRequest(bucket: bucket, key: key, uploadId: uploadID)
      _ = try? await Task { try await service.abortMultipartUpload(abort) }.value
      throw error
    }
  }

  /// `x-amz-copy-source`: the key and version are URL-encoded, keeping the key's "/".
  static func copySource(bucket: String, key: String, versionID: String?) -> String {
    let path = "\(bucket)/" + key.addingPercentEncoding(withAllowedCharacters: unreserved.union(["/"]))!
    guard let versionID else { return path }
    return path + "?versionId=" + versionID.addingPercentEncoding(withAllowedCharacters: unreserved)!
  }

  private static func formEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved)!
  }

  /// Reports local disk failures as such, so they aren't mistaken for S3 or SDK errors.
  private static func fileOperation<T>(reading: Bool = false, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      let error = error as NSError
      throw S3Failure(
        category: .localFile,
        message: reading
          ? "The file couldn't be read. Check that it still exists and that OpenBucket can open it."
          : "The file couldn't be saved. Check the destination folder's permissions and free space.",
        technicalDetail: "File error: \(error.domain) \(error.code)")
    }
  }

  private static func decodeKey(_ value: String, isURLEncoded: Bool) throws -> String {
    guard isURLEncoded else { return value }
    // URL-encoded listings use form encoding: a literal "+" arrives as %2B, so "+" means space.
    guard let decoded = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
      throw S3Failure(category: .unknown, message: "S3 returned an invalid URL-encoded object key.")
    }
    return decoded
  }

  private static func decodePrefixes(_ prefixes: [S3.CommonPrefix]?, isURLEncoded: Bool) throws -> [String] {
    try (prefixes ?? []).compactMap { item in
      try item.prefix.map { try decodeKey($0, isURLEncoded: isURLEncoded) }
    }
  }

  /// The marker for the next page; a truncated listing without one is a visible failure, not a silent end.
  private static func nextMarker(_ isTruncated: Bool?, _ marker: String?) throws -> String? {
    guard isTruncated == true else { return nil }
    guard let marker else {
      throw S3Failure(category: .service, message: "S3 reported more results but sent no continuation token.")
    }
    return marker
  }

  private func withService<Value: Sendable>(
    profile: ConnectionProfile,
    credentials: S3Credentials,
    bucket: String?,
    timeout: SotoCore.TimeAmount = .seconds(20),
    writing: Bool = false,
    operation: @Sendable (S3) async throws -> Value
  ) async throws -> Value {
    if let problem = profile.addressingProblem(bucket: bucket) {
      throw S3Failure(category: .regionOrEndpoint, message: problem)
    }
    let client = AWSClient(
      credentialProvider: .static(
        accessKeyId: credentials.accessKeyID,
        secretAccessKey: credentials.secretAccessKey,
        sessionToken: credentials.sessionToken
      ),
      retryPolicy: .jitter(base: .milliseconds(200), maxRetries: 1),
      httpClient: httpClient
    )
    var endpoint = profile.endpoint.absoluteString
    if endpoint.hasSuffix("/") { endpoint.removeLast() }
    let service = S3(
      client: client,
      region: Region(rawValue: profile.region),
      endpoint: endpoint,
      timeout: timeout,
      options: profile.addressingStyle == .virtualHost ? [.s3ForceVirtualHost] : []
    )
    do {
      let value = try await operation(service)
      try? await client.shutdown()
      return value
    } catch {
      try? await client.shutdown()
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw S3ErrorMapper.map(error, writing: writing)
    }
  }
}

/// `length` bytes from the handle's current offset, in 64 KiB chunks read as the request consumes them.
private struct FileChunks: AsyncSequence, Sendable {
  let handle: FileHandle
  let length: Int64
  let didRead: @Sendable (Int) -> Void

  struct AsyncIterator: AsyncIteratorProtocol {
    let handle: FileHandle
    var remaining: Int64
    let didRead: @Sendable (Int) -> Void

    mutating func next() async throws -> Data? {
      guard remaining > 0 else { return nil }
      try Task.checkCancellation()
      let count = Int(Swift.min(remaining, 64 * 1024))
      let data = try SotoS3Repository.readChunk(handle, count: count)
      remaining -= Int64(data.count)
      didRead(data.count)
      return data
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(handle: handle, remaining: length, didRead: didRead)
  }
}

extension SotoS3Repository {
  /// The next `count` bytes; a file that shrank while uploading is a local failure.
  fileprivate static func readChunk(_ handle: FileHandle, count: Int) throws -> Data {
    try fileOperation(reading: true) {
      guard let data = try handle.read(upToCount: count), !data.isEmpty else {
        throw CocoaError(.fileReadUnknown)
      }
      return data
    }
  }
}

/// ListObjectVersions output with `StorageClass` as a plain string: Soto's model only allows "STANDARD",
/// but S3 reports the real class (e.g. GLACIER) for noncurrent versions, which would fail the whole page.
private struct VersionListing: AWSDecodableShape {
  struct Entry: Decodable {
    let key: String?
    let versionId: String?
    let isLatest: Bool?
    let lastModified: Date?
    let size: Int64?
    let eTag: String?
    let storageClass: String?

    private enum CodingKeys: String, CodingKey {
      case key = "Key"
      case versionId = "VersionId"
      case isLatest = "IsLatest"
      case lastModified = "LastModified"
      case size = "Size"
      case eTag = "ETag"
      case storageClass = "StorageClass"
    }
  }

  let commonPrefixes: [S3.CommonPrefix]?
  let deleteMarkers: [Entry]?
  let versions: [Entry]?
  let encodingType: S3.EncodingType?
  let isTruncated: Bool?
  let nextKeyMarker: String?
  let nextVersionIdMarker: String?

  private enum CodingKeys: String, CodingKey {
    case commonPrefixes = "CommonPrefixes"
    case deleteMarkers = "DeleteMarker"
    case versions = "Version"
    case encodingType = "EncodingType"
    case isTruncated = "IsTruncated"
    case nextKeyMarker = "NextKeyMarker"
    case nextVersionIdMarker = "NextVersionIdMarker"
  }
}
