import AsyncHTTPClient
import Foundation
import OpenBucketCore
import SotoCore
import Testing
import os

@testable import OpenBucketS3

private let emptyListing = """
  <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Name>photos</Name><Prefix>trip/</Prefix><KeyCount>0</KeyCount>
    <MaxKeys>500</MaxKeys><IsTruncated>false</IsTruncated>
  </ListBucketResult>
  """

/// Answers requests with `results` in order, repeating the last one.
private actor RecordingHTTPClient: AWSHTTPClient {
  private var recordedURLs: [URL] = []
  private var recordedHeaders: [HTTPHeaders] = []
  private var recordedMethods: [String] = []
  private var recordedBodies: [String] = []
  private var results: [Result<AWSHTTPResponse, any Error>]

  init(_ body: String = emptyListing) {
    results = [reply(200, body)]
  }

  init(result: Result<AWSHTTPResponse, any Error>) {
    results = [result]
  }

  init(results: [Result<AWSHTTPResponse, any Error>]) {
    self.results = results
  }

  func execute(request: AWSHTTPRequest, timeout: TimeAmount, logger: Logger) async throws -> AWSHTTPResponse {
    recordedURLs.append(request.url)
    recordedHeaders.append(request.headers)
    recordedMethods.append(request.method.rawValue)
    // Consuming a streamed body is what drives upload progress, as on the wire.
    let body = try await request.body.collect(upTo: .max)
    recordedBodies.append(body.getString(at: body.readerIndex, length: body.readableBytes) ?? "")
    return try (results.count > 1 ? results.removeFirst() : results[0]).get()
  }

  func headers() -> [HTTPHeaders] { recordedHeaders }

  func methods() -> [String] { recordedMethods }

  func bodies() -> [String] { recordedBodies }

  func paths() -> [String] {
    recordedURLs.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "" }
  }

  func hosts() -> [String] { recordedURLs.compactMap(\.host) }

  func queries() -> [String] {
    recordedURLs.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
  }
}

private let credentials = S3Credentials(accessKeyID: "test", secretAccessKey: "test")

private func profile(_ endpoint: String, _ style: AddressingStyle = .path) throws -> ConnectionProfile {
  ConnectionProfile(
    name: "Test", endpoint: try S3Endpoint(endpoint), region: "garage", addressingStyle: style)
}

private func list(
  _ transport: RecordingHTTPClient, _ profile: ConnectionProfile, bucket: String = "photos"
) async throws -> ObjectPage {
  try await SotoS3Repository(httpClient: transport).listObjects(
    profile: profile, credentials: credentials, bucket: bucket, prefix: "", continuationToken: nil)
}

private func reply(_ status: Int, _ body: String = "", headers: HTTPHeaders = HTTPHeaders())
  -> Result<AWSHTTPResponse, any Error>
{
  .success(
    AWSHTTPResponse(status: .init(statusCode: status), headers: headers, body: AWSHTTPBody(string: body)))
}

private func download(
  _ transport: RecordingHTTPClient,
  to destination: URL,
  using gateway: ConnectionProfile? = nil,
  key: String = "trip/a b.txt",
  versionID: String? = nil,
  maximumBytes: Int64 = 100,
  progress: @escaping @Sendable (Int64) -> Void = { _ in }
) async throws {
  try await SotoS3Repository(httpClient: transport).downloadObject(
    profile: try gateway ?? profile("http://storage.example.com/s3/"),
    credentials: credentials,
    bucket: "photos",
    key: key,
    versionID: versionID,
    to: destination,
    maximumBytes: maximumBytes,
    progress: progress
  )
}

/// The S3Failure `operation` throws, or nil when it succeeds or throws something else.
private func failure<T>(_ operation: () async throws -> T) async -> S3Failure? {
  do {
    _ = try await operation()
    return nil
  } catch {
    return error as? S3Failure
  }
}

private func temporaryURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("openbucket-\(UUID().uuidString)")
}

@Test func virtualHostStyleMovesBucketIntoHostname() async throws {
  let transport = RecordingHTTPClient()
  _ = try await list(transport, profile("http://storage.example.com", .virtualHost))

  #expect(await transport.hosts() == ["photos.storage.example.com"])
  #expect(await transport.paths() == ["/"])
}

@Test func virtualHostWithEndpointPathFailsBeforeSending() async throws {
  let transport = RecordingHTTPClient()
  let gateway = try profile("http://storage.example.com/s3/", .virtualHost)

  #expect(await failure { try await list(transport, gateway) }?.category == .regionOrEndpoint)
  let buckets = await failure {
    try await SotoS3Repository(httpClient: transport).listBuckets(profile: gateway, credentials: credentials)
  }
  #expect(buckets?.category == .regionOrEndpoint)
  #expect(await transport.paths().isEmpty)
}

@Test func virtualHostWithDottedBucketFailsBeforeSending() async throws {
  let transport = RecordingHTTPClient()
  let gateway = try profile("http://storage.example.com", .virtualHost)

  let dotted = await failure { try await list(transport, gateway, bucket: "my.photos") }
  #expect(dotted?.category == .regionOrEndpoint)
  #expect(await transport.paths().isEmpty)
}

@Test func refusesExplicitPathStyleWhenSotoWouldMoveBucketIntoAmazonHost() async throws {
  let transport = RecordingHTTPClient()
  let amazon = try profile("https://s3.us-east-1.amazonaws.com")

  #expect(await failure { try await list(transport, amazon) }?.category == .regionOrEndpoint)
  #expect(await transport.paths().isEmpty)
}

@Test func signedRequestKeepsEndpointPathWithoutDoubleSlash() async throws {
  let transport = RecordingHTTPClient()
  _ = try await list(transport, profile("http://storage.example.com/s3/"))

  #expect(await transport.paths() == ["/s3/photos"])
}

@Test func downloadUsesTheSignedObjectKeyAndReportsProgress() async throws {
  let transport = RecordingHTTPClient("hello")
  let file = temporaryURL()
  defer { try? FileManager.default.removeItem(at: file) }
  let received = OSAllocatedUnfairLock(initialState: Int64(0))

  try await download(transport, to: file, versionID: "v 1") { bytes in received.withLock { $0 = bytes } }

  #expect(try String(contentsOf: file, encoding: .utf8) == "hello")
  #expect(received.withLock { $0 } == 5)
  #expect(await transport.paths() == ["/s3/photos/trip/a%20b.txt"])
  #expect(await transport.queries().first?.contains("versionId=v%201") == true)
}

@Test func downloadLimitPreservesAnExistingDestination() async throws {
  let directory = temporaryURL()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("existing.txt")
  try "original".write(to: destination, atomically: true, encoding: .utf8)

  let tooLarge = await failure {
    try await download(RecordingHTTPClient("too long"), to: destination, maximumBytes: 3)
  }
  #expect(tooLarge != nil)
  #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.txt"])
}

@Test func downloadsAnEmptyObject() async throws {
  let destination = temporaryURL()
  defer { try? FileManager.default.removeItem(at: destination) }

  try await download(RecordingHTTPClient(""), to: destination, maximumBytes: .max)

  #expect(try Data(contentsOf: destination).isEmpty)
}

@Test func downloadIntoMissingFolderIsALocalFileFailure() async throws {
  let destination = temporaryURL().appendingPathComponent("missing-folder/file.txt")

  let failure = await failure { try await download(RecordingHTTPClient("hello"), to: destination) }

  #expect(failure?.category == .localFile)
  #expect(failure?.technicalDetail?.contains("missing-folder") == false)
}

@Test func cancellationPassesThroughUnmapped() async throws {
  let transport = RecordingHTTPClient(result: .failure(CancellationError()))
  await #expect(throws: CancellationError.self) {
    _ = try await list(transport, profile("http://storage.example.com"))
  }
}

@Test func classifiesS3ErrorCodesWithoutEchoingServiceMessages() {
  let cases: [(String, S3Failure.Category)] = [
    ("AccessDenied", .authorization),
    ("InvalidAccessKeyId", .authentication),
    ("RequestTimeTooSkewed", .authentication),
    ("AuthorizationHeaderMalformed", .regionOrEndpoint),
    ("NoSuchKey", .notFound),
    ("NoSuchBucket", .notFound),
    ("SlowDown", .service),
    ("NotImplemented", .unsupportedOperation),
    ("EntityTooLarge", .service),
    ("KeyTooLong", .unknown),
    ("InvalidObjectName", .unknown),
    ("NoSuchUpload", .notFound),
  ]
  for (code, category) in cases {
    #expect(S3ErrorMapper.map(AWSResponseError(errorCode: code)).category == category, "\(code)")
  }
  let hostile = S3ErrorMapper.map(AWSResponseError(errorCode: "secret <b>endpoint</b>"))
  #expect(hostile.technicalDetail?.contains("secret") == false)
}

@Test func unparsableErrorBodyFallsBackOnHTTPStatus() async throws {
  let gateway = try profile("http://storage.example.com")
  let page = AWSHTTPBody(string: "<html>secret proxy page</html>")
  let badGateway = RecordingHTTPClient(
    result: .success(AWSHTTPResponse(status: .badGateway, headers: HTTPHeaders(), body: page)))
  let forbidden = RecordingHTTPClient(
    result: .success(AWSHTTPResponse(status: .forbidden, headers: HTTPHeaders(), body: page)))

  let busy = await failure { try await list(badGateway, gateway) }
  #expect(busy?.category == .service)
  #expect(busy?.technicalDetail?.contains("secret") == false)
  #expect(await failure { try await list(forbidden, gateway) }?.category == .authorization)
}

@Test func classifiesTimeoutsAndKeepsResponseDecodingErrorsOutOfLocalFiles() {
  #expect(S3ErrorMapper.map(HTTPClientError.deadlineExceeded).category == .timeout)
  #expect(S3ErrorMapper.map(HTTPClientError.remoteConnectionClosed).category == .network)
  // Soto throws DecodingError, which bridges to NSCocoaErrorDomain, for malformed listings.
  let malformed = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad date"))
  #expect(S3ErrorMapper.map(malformed).category == .unknown)
}

@Test func classifiesMacOSTransportFailuresWithoutLeakingDescription() {
  let tls = S3ErrorMapper.map(HTTPClient.NWTLSError(-9807, reason: "secret endpoint details"))
  let refused = S3ErrorMapper.map(HTTPClient.NWPOSIXError(.ECONNREFUSED, reason: "secret endpoint details"))
  #expect(tls.category == .tls)
  #expect(refused.category == .network)
  #expect(tls.technicalDetail?.contains("secret") == false)
  #expect(refused.technicalDetail?.contains("secret") == false)
}

@Test func decodesURLEncodedListingKeysExactlyOnce() async throws {
  let transport = RecordingHTTPClient(
    """
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>photos</Name><EncodingType>url</EncodingType>
      <CommonPrefixes><Prefix>a%252Fb/</Prefix></CommonPrefixes>
      <Contents><Key>a%252Fb/file%281%29%01</Key><Size>1</Size></Contents>
      <IsTruncated>false</IsTruncated>
    </ListBucketResult>
    """)
  let page = try await list(transport, profile("https://storage.example.com"))

  #expect(page.prefixes == ["a%2Fb/"])
  #expect(page.objects.map(\.key) == ["a%2Fb/file(1)\u{01}"])
  #expect(await transport.queries().first?.contains("encoding-type=url") == true)
}

@Test func decodesPlusAsSpaceInURLEncodedListings() async throws {
  let transport = RecordingHTTPClient(
    """
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>photos</Name><EncodingType>url</EncodingType>
      <CommonPrefixes><Prefix>a+b/</Prefix></CommonPrefixes>
      <CommonPrefixes><Prefix>a%2Bb/</Prefix></CommonPrefixes>
      <Contents><Key>a+b</Key><Size>1</Size></Contents>
      <Contents><Key>a%2Bb</Key><Size>1</Size></Contents>
      <IsTruncated>false</IsTruncated>
    </ListBucketResult>
    """)
  let page = try await list(transport, profile("https://storage.example.com"))

  #expect(page.prefixes == ["a b/", "a+b/"])
  #expect(page.objects.map(\.key) == ["a b", "a+b"])
}

@Test func truncatedListingWithoutTokenIsAVisibleFailure() async throws {
  let transport = RecordingHTTPClient(
    """
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>photos</Name><Contents><Key>a</Key><Size>1</Size></Contents>
      <IsTruncated>true</IsTruncated>
    </ListBucketResult>
    """)
  let gateway = try profile("https://storage.example.com")

  #expect(await failure { try await list(transport, gateway) }?.category == .service)
}

private func presign(
  _ transport: RecordingHTTPClient, _ gateway: ConnectionProfile, key: String, versionID: String? = nil,
  expiresIn: Duration = .seconds(3600), downloadFileName: String? = nil
) async throws -> URLComponents {
  let url = try await SotoS3Repository(httpClient: transport).presignedURL(
    profile: gateway, credentials: credentials, bucket: "photos", key: key, versionID: versionID,
    expiresIn: expiresIn, downloadFileName: downloadFileName)
  return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
}

@Test func presignedURLKeepsEndpointPathAndMatchesTheRequestSotoSends() async throws {
  let transport = RecordingHTTPClient("x")
  let gateway = try profile("http://storage.example.com/s3/")
  let key = "trip/a b+c/\u{00E9}%.jpg"

  let signed = try await presign(transport, gateway, key: key, versionID: "v 1")
  #expect(await transport.paths().isEmpty)
  #expect(signed.host == "storage.example.com")
  #expect(signed.percentEncodedPath == "/s3/photos/trip/a%20b%2Bc/%C3%A9%25.jpg")
  let query = signed.percentEncodedQuery ?? ""
  #expect(query.contains("X-Amz-Expires=3600"))
  #expect(query.contains("versionId=v%201"))
  #expect(query.contains("X-Amz-Signature="))

  let file = temporaryURL()
  defer { try? FileManager.default.removeItem(at: file) }
  try await download(transport, to: file, using: gateway, key: key)
  #expect(await transport.paths() == [signed.percentEncodedPath])
}

@Test func presignedURLUsesVirtualHostLikeSotoForAmazon() async throws {
  let transport = RecordingHTTPClient("x")
  let amazon = try profile("https://s3.us-east-1.amazonaws.com", .automatic)

  let signed = try await presign(transport, amazon, key: "a.jpg")
  let file = temporaryURL()
  defer { try? FileManager.default.removeItem(at: file) }
  try await download(transport, to: file, using: amazon, key: "a.jpg")

  #expect(signed.host == "photos.s3.us-east-1.amazonaws.com")
  #expect(await transport.hosts() == [signed.host])
  #expect(await transport.paths() == [signed.percentEncodedPath])
}

@Test func presignedURLSignsADownloadFileName() async throws {
  let gateway = try profile("http://storage.example.com")
  let signed = try await presign(
    RecordingHTTPClient(), gateway, key: "a", versionID: "v 1",
    downloadFileName: "R\u{00E9}\"sum\u{00E9} 'v2'&.pdf")

  let disposition = signed.queryItems?.first { $0.name == "response-content-disposition" }?.value
  #expect(
    disposition
      == "attachment; filename=\"R__sum_ 'v2'&.pdf\"; filename*=UTF-8''R%C3%A9%22sum%C3%A9%20%27v2%27&.pdf")
  // S3 recomputes the canonical query by sorting and strictly re-encoding; the signed query must already be
  // in that form or the signature won't match.
  let pairs = (signed.percentEncodedQuery ?? "").split(separator: "&")
  let unsigned = pairs.filter { !$0.hasPrefix("X-Amz-Signature=") }
  #expect(unsigned == unsigned.sorted())
  #expect(unsigned.allSatisfy { $0.wholeMatch(of: #/[A-Za-z-]+=([A-Za-z0-9._~-]|%[0-9A-F]{2})*/#) != nil })
  #expect(pairs.contains { $0.wholeMatch(of: #/X-Amz-Signature=[0-9a-f]{64}/#) != nil })

  let inline = try await presign(RecordingHTTPClient(), gateway, key: "a")
  #expect(inline.queryItems?.contains { $0.name == "response-content-disposition" } == false)
}

@Test func presignedURLRejectsExpiryOutsideOneSecondToSevenDays() async throws {
  let gateway = try profile("http://storage.example.com")
  for expiry in [Duration.zero, .seconds(7 * 86_400 + 1)] {
    #expect(
      await failure { try await presign(RecordingHTTPClient(), gateway, key: "a", expiresIn: expiry) } != nil)
  }
  _ = try await presign(RecordingHTTPClient(), gateway, key: "a", expiresIn: .seconds(7 * 86_400))
}

@Test func readObjectBytesSendsRangeAndCapsToIt() async throws {
  let gateway = try profile("http://storage.example.com")
  func read(_ transport: RecordingHTTPClient, _ range: Range<Int64>) async throws -> Data {
    try await SotoS3Repository(httpClient: transport).readObjectBytes(
      profile: gateway, credentials: credentials, bucket: "photos", key: "a.jpg", range: range)
  }

  let partial = RecordingHTTPClient(
    result: reply(206, "2345", headers: ["Content-Range": "bytes 2-5/10"]))
  #expect(try await read(partial, 2..<6) == Data("2345".utf8))
  #expect(await partial.headers().first?["Range"] == ["bytes=2-5"])

  // A server that ignores Range sends everything from byte 0.
  #expect(try await read(RecordingHTTPClient("0123456789"), 2..<6) == Data("2345".utf8))

  let invalid = "<Error><Code>InvalidRange</Code><Message>secret</Message></Error>"
  #expect(try await read(RecordingHTTPClient(result: reply(416, invalid)), 20..<30).isEmpty)

  let unused = RecordingHTTPClient()
  #expect(try await read(unused, 5..<5).isEmpty)
  #expect(await unused.paths().isEmpty)
}

@Test func objectDetailsKeepsHeadWhenTaggingFails() async throws {
  let gateway = try profile("http://storage.example.com")
  let head = reply(
    200,
    headers: [
      "Content-Type": "image/jpeg", "x-amz-meta-Owner": "rael", "x-amz-storage-class": "GLACIER",
      "x-amz-version-id": "v1",
    ])
  let denied = reply(403, "<Error><Code>AccessDenied</Code></Error>")
  let tagging = reply(200, "<Tagging><TagSet><Tag><Key>team</Key><Value>ops</Value></Tag></TagSet></Tagging>")
  func details(_ results: [Result<AWSHTTPResponse, any Error>]) async throws -> ObjectDetails {
    try await SotoS3Repository(httpClient: RecordingHTTPClient(results: results)).objectDetails(
      profile: gateway, credentials: credentials, bucket: "photos", key: "a.jpg", versionID: "v1")
  }

  let withoutTags = try await details([head, denied])
  #expect(withoutTags.contentType == "image/jpeg")
  #expect(withoutTags.storageClass == "GLACIER")
  #expect(withoutTags.versionID == "v1")
  #expect(withoutTags.metadata == ["owner": "rael"])
  #expect(withoutTags.tags == nil)
  #expect(try await details([head, tagging]).tags == ["team": "ops"])
}

@Test func objectDetailsReportsAMissingObjectForAHead404() async throws {
  let gateway = try profile("http://storage.example.com")
  let missing = await failure {
    try await SotoS3Repository(httpClient: RecordingHTTPClient(result: reply(404))).objectDetails(
      profile: gateway, credentials: credentials, bucket: "photos", key: "gone.jpg", versionID: "v1")
  }
  #expect(missing?.category == .notFound)
  #expect(missing?.message == "This object no longer exists. Refresh the folder.")
}

@Test func listObjectVersionsMergesDeleteMarkersInS3Order() async throws {
  let transport = RecordingHTTPClient(
    """
    <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>photos</Name><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>
      <NextKeyMarker>b+c</NextKeyMarker><NextVersionIdMarker>v9</NextVersionIdMarker>
      <Version><Key>a</Key><VersionId>a1</VersionId><IsLatest>false</IsLatest>
        <LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>"e"</ETag><Size>3</Size>
        <StorageClass>STANDARD</StorageClass></Version>
      <Version><Key>b+c</Key><VersionId>b1</VersionId><IsLatest>true</IsLatest>
        <LastModified>2026-01-01T00:00:00.000Z</LastModified><Size>4</Size>
        <StorageClass>GLACIER</StorageClass></Version>
      <DeleteMarker><Key>a</Key><VersionId>a2</VersionId><IsLatest>true</IsLatest>
        <LastModified>2026-02-01T00:00:00.000Z</LastModified></DeleteMarker>
      <CommonPrefixes><Prefix>dir%2Bx/</Prefix></CommonPrefixes>
    </ListVersionsResult>
    """)
  let page = try await SotoS3Repository(httpClient: transport).listObjectVersions(
    profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
    prefix: "",
    delimiter: "/", keyMarker: nil, versionIDMarker: nil)

  #expect(page.versions.map(\.versionID) == ["a2", "a1", "b1"])
  #expect(page.versions.map(\.isDeleteMarker) == [true, false, false])
  #expect(page.versions.map(\.key) == ["a", "a", "b c"])
  #expect(page.versions.map(\.storageClass) == [nil, "STANDARD", "GLACIER"])
  #expect(page.prefixes == ["dir+x/"])
  #expect(page.nextKeyMarker == "b c")
  #expect(page.nextVersionIDMarker == "v9")
  let query = await transport.queries().first ?? ""
  #expect(query.contains("versions") && query.contains("encoding-type=url"))
}

@Test func versionListingOnAProviderWithoutItIsUnsupported() async throws {
  let transport = RecordingHTTPClient(result: reply(501, "<html>secret</html>"))
  let failure = await failure {
    try await SotoS3Repository(httpClient: transport).listObjectVersions(
      profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
      prefix: "", delimiter: nil, keyMarker: nil, versionIDMarker: nil)
  }
  #expect(failure?.category == .unsupportedOperation)
}

@Test func listAllObjectsHasNoDelimiterAndMapsStorageClass() async throws {
  let transport = RecordingHTTPClient(
    """
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>photos</Name><Contents><Key>a/b</Key><Size>1</Size><StorageClass>GLACIER</StorageClass></Contents>
      <IsTruncated>false</IsTruncated>
    </ListBucketResult>
    """)
  let page = try await SotoS3Repository(httpClient: transport).listAllObjects(
    profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
    prefix: "",
    continuationToken: nil)

  #expect(page.objects.map(\.storageClass) == ["GLACIER"])
  let query = await transport.queries().first ?? ""
  #expect(!query.contains("delimiter") && query.contains("max-keys=1000"))
}

@Test func unusableAWSProfileIsAMissingCredentialsFailure() async throws {
  let name = "openbucket-missing-\(UUID().uuidString)"
  let failure = await failure {
    try await SotoS3Repository(httpClient: RecordingHTTPClient()).resolveAWSProfile(name)
  }
  #expect(failure?.category == .missingCredentials)
  #expect(failure?.message.contains("aws sso login --profile \(name)") == true)
}

private func upload(
  _ transport: RecordingHTTPClient, _ file: URL, headers: ObjectHeaders = ObjectHeaders(),
  progress: @escaping @Sendable (Int64) -> Void = { _ in }
) async throws {
  try await SotoS3Repository(httpClient: transport).uploadFile(
    profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
    key: "trip/a b.txt", from: file, headers: headers, progress: progress)
}

private func copy(
  _ transport: RecordingHTTPClient, size: Int64 = 3, versionID: String? = "v 1", headers: ObjectHeaders?
) async throws {
  try await SotoS3Repository(httpClient: transport).copyObject(
    profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
    sourceKey: "a b+c.txt", sourceVersionID: versionID, size: size, destinationKey: "copy.txt",
    headers: headers)
}

private let createdUpload = reply(
  200,
  "<InitiateMultipartUploadResult><Bucket>photos</Bucket><Key>k</Key><UploadId>u1</UploadId>"
    + "</InitiateMultipartUploadResult>")
private let completedUpload = reply(
  200, "<CompleteMultipartUploadResult><ETag>\"x\"</ETag></CompleteMultipartUploadResult>")

@Test func smallUploadIsOnePutWithHeadersMetadataAndProgress() async throws {
  let file = temporaryURL()
  try "hello".write(to: file, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: file) }
  let transport = RecordingHTTPClient("")
  let sent = OSAllocatedUnfairLock(initialState: Int64(0))

  try await upload(
    transport, file,
    headers: ObjectHeaders(contentType: "text/plain", cacheControl: "no-cache", metadata: ["owner": "rael"])
  ) { bytes in sent.withLock { $0 = bytes } }

  #expect(await transport.methods() == ["PUT"])
  #expect(await transport.paths() == ["/photos/trip/a%20b.txt"])
  let headers = try #require(await transport.headers().first)
  #expect(headers["content-type"] == ["text/plain"])
  #expect(headers["cache-control"] == ["no-cache"])
  #expect(headers["x-amz-meta-owner"] == ["rael"])
  #expect(headers["x-amz-decoded-content-length"] == ["5"])
  #expect(await transport.bodies().first?.contains("hello") == true)
  #expect(sent.withLock { $0 } == 5)
}

@Test func partSizeStaysAtTheMinimumUntilTenThousandPartsWouldNotFit() {
  let minimum = SotoS3Repository.singlePutLimit
  #expect(SotoS3Repository.partSize(for: 1, minimum: minimum) == minimum)
  #expect(SotoS3Repository.partSize(for: minimum * 10_000, minimum: minimum) == minimum)
  let huge: Int64 = 5 * 1024 * 1024 * 1024 * 1024
  let part = SotoS3Repository.partSize(for: huge, minimum: minimum)
  #expect(part > minimum && (huge + part - 1) / part <= 10_000)
}

@Test func uploadAboveSixteenMiBIsMultipartInOrder() async throws {
  let file = temporaryURL()
  let size = SotoS3Repository.singlePutLimit + 1
  FileManager.default.createFile(atPath: file.path, contents: nil)
  defer { try? FileManager.default.removeItem(at: file) }
  try FileHandle(forWritingTo: file).truncate(atOffset: UInt64(size))
  let transport = RecordingHTTPClient(results: [
    createdUpload, reply(200, headers: ["ETag": "\"p1\""]), reply(200, headers: ["ETag": "\"p2\""]),
    completedUpload,
  ])
  let sent = OSAllocatedUnfairLock(initialState: Int64(0))

  try await upload(transport, file) { bytes in sent.withLock { $0 = bytes } }

  #expect(await transport.methods() == ["POST", "PUT", "PUT", "POST"])
  let queries = await transport.queries()
  #expect(queries[0].contains("uploads"))
  #expect(queries[1].contains("partNumber=1") && queries[1].contains("uploadId=u1"))
  #expect(queries[2].contains("partNumber=2"))
  let headers = await transport.headers()
  #expect(headers[1]["x-amz-decoded-content-length"] == ["\(SotoS3Repository.singlePutLimit)"])
  #expect(headers[2]["x-amz-decoded-content-length"] == ["1"])
  let complete = await transport.bodies()[3]
  #expect(complete.contains("p1") && complete.contains("<PartNumber>2</PartNumber>"))
  #expect(sent.withLock { $0 } == size)
}

@Test func failedOrCancelledMultipartUploadIsAborted() async throws {
  let file = temporaryURL()
  FileManager.default.createFile(atPath: file.path, contents: nil)
  defer { try? FileManager.default.removeItem(at: file) }
  try FileHandle(forWritingTo: file).truncate(atOffset: UInt64(SotoS3Repository.singlePutLimit + 1))

  let failing = RecordingHTTPClient(results: [
    createdUpload, reply(500, "<Error><Code>InternalError</Code></Error>"), reply(204),
  ])
  #expect(await failure { try await upload(failing, file) }?.category == .service)
  #expect(await failing.methods() == ["POST", "PUT", "DELETE"])
  #expect(await failing.queries().last?.contains("uploadId=u1") == true)

  let cancelled = RecordingHTTPClient(results: [createdUpload, .failure(CancellationError()), reply(204)])
  await #expect(throws: CancellationError.self) { try await upload(cancelled, file) }
  #expect(await cancelled.methods() == ["POST", "PUT", "DELETE"])
}

@Test func uploadOfAMissingFileIsALocalFileFailureWithoutARequest() async throws {
  let transport = RecordingHTTPClient("")
  let missing = temporaryURL().appendingPathComponent("secret-folder/file.txt")

  let failure = await failure { try await upload(transport, missing) }

  #expect(failure?.category == .localFile)
  #expect(failure?.technicalDetail?.contains("secret-folder") == false)
  #expect(await transport.methods().isEmpty)
}

@Test func copyKeepsOrReplacesMetadataAndEncodesTheVersionedSource() async throws {
  let copied = reply(200, "<CopyObjectResult><ETag>\"e\"</ETag></CopyObjectResult>")
  let keep = RecordingHTTPClient(result: copied)
  try await copy(keep, headers: nil)
  let kept = try #require(await keep.headers().first)
  #expect(kept["x-amz-copy-source"] == ["photos/a%20b%2Bc.txt?versionId=v%201"])
  #expect(kept["x-amz-metadata-directive"] == ["COPY"])
  #expect(await keep.paths() == ["/photos/copy.txt"])

  let replace = RecordingHTTPClient(result: copied)
  try await copy(
    replace, versionID: nil, headers: ObjectHeaders(contentType: "image/png", metadata: ["owner": "rael"]))
  let replaced = try #require(await replace.headers().first)
  #expect(replaced["x-amz-copy-source"] == ["photos/a%20b%2Bc.txt"])
  #expect(replaced["x-amz-metadata-directive"] == ["REPLACE"])
  #expect(replaced["content-type"] == ["image/png"])
  #expect(replaced["x-amz-meta-owner"] == ["rael"])
}

@Test func copyOntoItsOwnKeyReplacesWithTheSourceVersionHeaders() async throws {
  let head = reply(200, headers: ["Content-Type": "text/plain", "x-amz-meta-Owner": "rael"])
  let copied = reply(200, "<CopyObjectResult><ETag>\"e\"</ETag></CopyObjectResult>")
  let transport = RecordingHTTPClient(results: [head, reply(501), copied])

  try await SotoS3Repository(httpClient: transport).copyObject(
    profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
    sourceKey: "a.txt", sourceVersionID: "old", size: 3, destinationKey: "a.txt", headers: nil)

  #expect(await transport.methods() == ["HEAD", "GET", "PUT"])
  #expect(await transport.queries()[0].contains("versionId=old"))
  let headers = try #require(await transport.headers().last)
  #expect(headers["x-amz-copy-source"] == ["photos/a.txt?versionId=old"])
  #expect(headers["x-amz-metadata-directive"] == ["REPLACE"])
  #expect(headers["content-type"] == ["text/plain"])
  #expect(headers["x-amz-meta-owner"] == ["rael"])
}

@Test func copyAboveFiveGiBIsMultipartWithTheSourceHeadersAndTags() async throws {
  let size = SotoS3Repository.singleCopyLimit + 1
  let head = reply(200, headers: ["Content-Type": "video/mp4", "x-amz-meta-Owner": "rael"])
  let tagging = reply(
    200, "<Tagging><TagSet><Tag><Key>team</Key><Value>a&amp;b</Value></Tag></TagSet></Tagging>")
  let part = reply(200, "<CopyPartResult><ETag>\"p\"</ETag></CopyPartResult>")
  let transport = RecordingHTTPClient(
    results: [head, tagging, createdUpload] + Array(repeating: part, count: 11) + [completedUpload])

  try await copy(transport, size: size, headers: nil)

  let methods = await transport.methods()
  #expect(methods == ["HEAD", "GET", "POST"] + Array(repeating: "PUT", count: 11) + ["POST"])
  let headers = await transport.headers()
  #expect(headers[2]["content-type"] == ["video/mp4"])
  #expect(headers[2]["x-amz-meta-owner"] == ["rael"])
  #expect(headers[2]["x-amz-tagging"] == ["team=a%26b"])
  #expect(headers[3]["x-amz-copy-source"] == ["photos/a%20b%2Bc.txt?versionId=v%201"])
  #expect(headers[3]["x-amz-copy-source-range"] == ["bytes=0-536870911"])
  #expect(headers[13]["x-amz-copy-source-range"] == ["bytes=5368709120-5368709120"])
}

@Test func deleteObjectsBatchesByThousandWithContentMD5AndReportsKeyErrors() async throws {
  let transport = RecordingHTTPClient(results: [
    reply(200, "<DeleteResult></DeleteResult>"),
    reply(
      200,
      "<DeleteResult><Error><Key>k1000</Key><Code>AccessDenied</Code><Message>secret</Message></Error>"
        + "</DeleteResult>"),
  ])
  let keys = (0...1000).map { "k\($0)" }

  let failures = try await SotoS3Repository(httpClient: transport).deleteObjects(
    profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos", keys: keys
  )

  let denied = "This connection's credentials can't change objects here."
  #expect(failures == [DeleteFailure(key: "k1000", message: denied)])
  #expect(await transport.methods() == ["POST", "POST"])
  #expect(await transport.queries().allSatisfy { $0.contains("delete") })
  #expect(await transport.headers().allSatisfy { $0["content-md5"].first != nil })
  let bodies = await transport.bodies()
  #expect(bodies.map { $0.components(separatedBy: "<Key>").count - 1 } == [1000, 1])
  #expect(bodies[0].contains("<Quiet>true</Quiet>"))
  #expect(bodies[1].contains("<Key>k1000</Key>"))
}

@Test func putObjectTagsSendsTheSortedTagSetAndDeletesForNone() async throws {
  func put(_ transport: RecordingHTTPClient, _ tags: [String: String]) async throws {
    try await SotoS3Repository(httpClient: transport).putObjectTags(
      profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos",
      key: "a.jpg", tags: tags)
  }
  let tagged = RecordingHTTPClient("")
  try await put(tagged, ["b": "2", "a": "1"])
  #expect(await tagged.methods() == ["PUT"])
  #expect(await tagged.queries().first?.contains("tagging") == true)
  #expect(await tagged.headers().first?["content-md5"].first != nil)
  let body = await tagged.bodies().first ?? ""
  #expect(body.contains("<Tag><Key>a</Key><Value>1</Value></Tag><Tag><Key>b</Key><Value>2</Value></Tag>"))

  let cleared = RecordingHTTPClient(result: reply(204))
  try await put(cleared, [:])
  #expect(await cleared.methods() == ["DELETE"])
  #expect(await cleared.queries().first?.contains("tagging") == true)
}

@Test func bucketVersioningReadsTheStatus() async throws {
  func versioning(_ body: String) async throws -> BucketVersioning {
    try await SotoS3Repository(httpClient: RecordingHTTPClient(body)).bucketVersioning(
      profile: try profile("http://storage.example.com"), credentials: credentials, bucket: "photos")
  }
  #expect(
    try await versioning("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>")
      == .enabled)
  #expect(
    try await versioning("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>")
      == .suspended)
  #expect(try await versioning("<VersioningConfiguration/>") == .disabled)
}

@Test func deniedWritesSayTheConnectionCantChangeObjects() async throws {
  let gateway = try profile("http://storage.example.com")
  let denied = reply(403, "<Error><Code>AccessDenied</Code></Error>")
  let transport = RecordingHTTPClient(result: denied)
  let write = await failure {
    try await SotoS3Repository(httpClient: transport).putEmptyObject(
      profile: gateway, credentials: credentials, bucket: "photos", key: "new folder/")
  }
  #expect(write?.category == .authorization)
  #expect(write?.message == "This connection's credentials can't change objects here.")
  #expect(await transport.methods() == ["PUT"])
  #expect(await transport.paths() == ["/photos/new%20folder/"])

  let read = await failure { try await list(RecordingHTTPClient(result: denied), gateway) }
  #expect(read?.message == "Access to this S3 operation was denied.")
}
