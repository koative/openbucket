import CryptoKit
import Foundation
import ImageIO
import OpenBucketCore
import Testing
import UniformTypeIdentifiers

@testable import OpenBucket

/// Lists `objects` under the requested prefix, `pageSize` at a time; downloads write the key's bytes.
/// `repeatsToken` hands out continuation token "1" for every page, like a broken server.
private actor ListingRepository: S3Repository {
  let objects: [ObjectSummary]
  let pageSize: Int
  let repeatsToken: Bool

  init(_ objects: [ObjectSummary], pageSize: Int = 1000, repeatsToken: Bool = false) {
    self.objects = objects
    self.pageSize = pageSize
    self.repeatsToken = repeatsToken
  }

  init(keys: [String], pageSize: Int = 1000) {
    self.init(keys.map { ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil) }, pageSize: pageSize)
  }

  func listBuckets(profile: ConnectionProfile, credentials: S3Credentials) -> [String] { [] }

  func listObjects(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, prefix: String,
    continuationToken: String?
  ) throws -> ObjectPage { throw unused }

  func listAllObjects(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, prefix: String,
    continuationToken: String?
  ) -> ObjectPage {
    let matching = objects.filter { $0.key.utf8.starts(with: prefix.utf8) }
    let start = continuationToken.flatMap { Int($0) } ?? 0
    let end = min(start + pageSize, matching.count)
    return ObjectPage(
      prefixes: [], objects: Array(matching[start..<end]),
      nextToken: end < matching.count ? (repeatsToken ? "1" : "\(end)") : nil)
  }

  func listObjectVersions(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, prefix: String,
    delimiter: String?,
    keyMarker: String?, versionIDMarker: String?
  ) throws -> VersionPage { throw unused }

  func objectDetails(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, versionID: String?
  ) throws -> ObjectDetails { throw unused }

  func readObjectBytes(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, range: Range<Int64>
  ) throws -> Data { throw unused }

  func presignedURL(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, versionID: String?,
    expiresIn: Duration, downloadFileName: String?
  ) throws -> URL { throw unused }

  func resolveAWSProfile(_ name: String) throws -> S3Credentials { throw unused }

  func downloadObject(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, versionID: String?,
    to destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (_ bytesReceived: Int64) -> Void
  ) throws {
    let data = Data(key.utf8)
    try data.write(to: destination)
    progress(Int64(data.count))
  }

  func bucketVersioning(profile: ConnectionProfile, credentials: S3Credentials, bucket: String) throws
    -> BucketVersioning
  { throw unused }

  func uploadFile(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String, from source: URL,
    headers: ObjectHeaders, progress: @escaping @Sendable (_ bytesSent: Int64) -> Void
  ) throws { throw unused }

  func putEmptyObject(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String)
    throws
  {
    throw unused
  }

  func copyObject(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, sourceKey: String,
    sourceVersionID: String?, size: Int64, destinationKey: String, headers: ObjectHeaders?
  ) throws { throw unused }

  func deleteObjects(profile: ConnectionProfile, credentials: S3Credentials, bucket: String, keys: [String])
    throws -> [DeleteFailure]
  { throw unused }

  func putObjectTags(
    profile: ConnectionProfile, credentials: S3Credentials, bucket: String, key: String,
    tags: [String: String]
  ) throws { throw unused }

  private var unused: S3Failure { S3Failure(category: .unsupportedOperation, message: "Not used here.") }
}

private func source() throws -> AppModel.DownloadSource {
  AppModel.DownloadSource(profile: try garageProfile(), bucket: "test-bucket", credentials: testCredentials)
}

private func md5(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func object(_ key: String, _ data: Data, eTag: String? = nil) -> ObjectSummary {
  ObjectSummary(key: key, size: Int64(data.count), lastModified: nil, eTag: eTag ?? "\"\(md5(data))\"")
}

// MARK: - FolderDownloader

@Test func folderPathsSanitiseEveryComponentAndStayUniquePerDirectory() {
  let keys = [
    "root/", "root/a/b.txt", "root/A/b.txt", "root/a/B.TXT", "root/a/../../x", "root//abs",
    "root/d/\u{301}e.txt", "root/a/sub/", "other/escape.txt",
  ]
  let plan = FolderDownloader.localPaths(
    for: keys.map { ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil) }, under: "root/")

  #expect(
    plan.map(\.path) == [
      "a/b.txt", "A (2)/b.txt", "a/B (2).TXT", "a/object/object/x", "abs", "d/\u{301}e.txt",
    ])
  #expect(
    plan.map(\.object.key) == [
      "root/a/b.txt", "root/A/b.txt", "root/a/B.TXT", "root/a/../../x",
      "root//abs", "root/d/\u{301}e.txt",
    ])
}

@MainActor
@Test func folderDownloadRecreatesHierarchyInsideAFreshFolder() async throws {
  let parent = scratchDirectory()
  try FileManager.default.createDirectory(
    at: parent.appendingPathComponent("photos"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let repository = ListingRepository(keys: [
    "photos/", "photos/2024/a.jpg", "photos/../../escape.txt", "/photos/abs.txt", "photos/2024/",
  ])
  let progress = Recorder<BatchDownloadProgress>()

  let result = try await FolderDownloader(repository: repository).download(
    try S3Location(bucket: "test-bucket", prefix: "photos/"), from: try source(), into: parent
  ) { progress.values.append($0) }

  #expect(result.directory.lastPathComponent == "photos 2")
  #expect(result.downloaded == 2)
  #expect(result.failedKeys.isEmpty)
  #expect(
    try String(contentsOf: result.directory.appendingPathComponent("2024/a.jpg"), encoding: .utf8)
      == "photos/2024/a.jpg")
  #expect(
    try String(
      contentsOf: result.directory.appendingPathComponent("object/object/escape.txt"), encoding: .utf8)
      == "photos/../../escape.txt")
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == ["photos", "photos 2"])
  #expect(
    progress.values.last
      == BatchDownloadProgress(completedFiles: 2, totalFiles: 2, receivedBytes: 2, totalBytes: 2))
}

// MARK: - BackupVerification

@MainActor
@Test func backupVerificationClassifiesEveryPath() async throws {
  let folder = scratchDirectory()
  try FileManager.default.createDirectory(
    at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  func write(_ path: String, _ data: Data) throws {
    try data.write(to: folder.appendingPathComponent(path))
  }
  let hello = Data("hello".utf8)
  let big = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 13) })
  let multipartETag =
    md5(
      Data(Insecure.MD5.hash(data: big.prefix(8 << 20)))
        + Data(Insecure.MD5.hash(data: big.dropFirst(8 << 20))))
    + "-2"
  try write("same.txt", hello)
  try write("changed.txt", hello)
  try write("short.txt", Data("hi".utf8))
  try write("local-only.txt", hello)
  try write("sub/big.bin", big)
  try write("odd.bin", Data(count: 10))
  try write("cafe\u{301}.txt", hello)
  try write(".hidden", hello)
  try write("quote \"x\", y.txt", Data("q".utf8))
  try write("=SUM(A1).txt", hello)
  try write(".DS_Store", hello)
  try write("._same.txt", hello)
  try FileManager.default.createDirectory(
    at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
  try write(".git/config", hello)
  try write("locked.txt", hello)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0], ofItemAtPath: folder.appendingPathComponent("locked.txt").path)
  let repository = ListingRepository([
    object("backup/", Data()),
    object("backup/same.txt", hello),
    object("backup/changed.txt", hello, eTag: md5(Data("world".utf8))),
    object("backup/short.txt", Data("hi!".utf8)),
    object("backup/remote-only.txt", hello),
    object("backup/sub/big.bin", big, eTag: "\"\(multipartETag)\""),
    object("backup/odd.bin", Data(count: 10), eTag: "\"\(md5(hello))-3\""),
    object("backup/caf\u{E9}.txt", hello),
    object("backup/.git/config", hello),
    object("backup/locked.txt", hello),
    object("backup/sub/.DS_Store", hello),
  ])

  let verification = BackupVerification(
    repository: repository, source: try source(),
    location: try S3Location(bucket: "test-bucket", prefix: "backup/"),
    localFolder: folder)
  verification.start()
  await verification.task?.value

  #expect(verification.failure == nil)
  let statuses = Dictionary(uniqueKeysWithValues: verification.entries.map { ($0.relativePath, $0.status) })
  #expect(
    statuses == [
      "same.txt": .identical, "changed.txt": .different, "short.txt": .sizeMismatch,
      "local-only.txt": .missingInS3, "remote-only.txt": .onlyInS3, "sub/big.bin": .identical,
      "odd.bin": .unverified, "caf\u{E9}.txt": .identical, "quote \"x\", y.txt": .missingInS3,
      ".hidden": .missingInS3, ".git/config": .identical, "locked.txt": .unreadable,
      "=SUM(A1).txt": .missingInS3,
    ])
  #expect(
    verification.entries.contains {
      $0.relativePath.unicodeScalars.elementsEqual("caf\u{E9}.txt".unicodeScalars)
    })
  #expect(verification.checkedFiles == 13)
  #expect(verification.totalFiles == 13)
  let csv = verification.csv()
  #expect(csv.hasPrefix("path,status,local_size,remote_size\r\n"))
  #expect(csv.contains("\r\n\"quote \"\"x\"\", y.txt\",missingInS3,1,\r\n"))
  #expect(csv.contains("\r\nshort.txt,sizeMismatch,2,3\r\n"))
  #expect(csv.contains("\r\n'=SUM(A1).txt,missingInS3,5,\r\n"))
  #expect(csv.contains("\r\nlocked.txt,unreadable,5,5\r\n"))
}

// MARK: - ObjectListing

@MainActor
@Test func repeatedContinuationTokenFailsVisibly() async throws {
  let repository = ListingRepository(
    ["a", "b", "c"].map { ObjectSummary(key: $0, size: 1, lastModified: nil, eTag: nil) }, pageSize: 1,
    repeatsToken: true)
  let pages = Recorder<ObjectPage>()
  let failure = await #expect(throws: S3Failure.self) {
    try await source().forEachObjectPage(repository, prefix: "") { page in
      pages.values.append(page)
      return true
    }
  }
  #expect(failure?.category == .service)
  #expect(pages.values.count == 2)
}

// MARK: - DeepSearch

@MainActor
@Test func deepSearchMatchesRelativeKeysIgnoringCaseAndDiacritics() async throws {
  let repository = ListingRepository(
    keys: [
      "photos/\u{C9}t\u{E9}/Plage.JPG", "photos/ete/other.txt", "photos/x/plage.png", "photos/notes.txt",
    ],
    pageSize: 2)
  let search = DeepSearch(
    repository: repository, source: try source(), location: try S3Location(bucket: "b", prefix: "photos/"))

  search.run(query: " ETE ")
  await search.task?.value
  #expect(search.results.map(\.key) == ["photos/\u{C9}t\u{E9}/Plage.JPG", "photos/ete/other.txt"])
  #expect(search.scanned == 4)
  #expect(!search.truncated)
  #expect(!search.isRunning)

  search.run(query: "photos")
  await search.task?.value
  #expect(search.results.isEmpty)
}

@MainActor
@Test func deepSearchStopsAtItsLimits() async throws {
  let keys = ["f/a.txt", "f/b.txt", "f/c.txt", "f/d.txt"]
  let location = try S3Location(bucket: "b", prefix: "f/")
  let scanBound = DeepSearch(
    repository: ListingRepository(keys: keys, pageSize: 2), source: try source(), location: location,
    scanLimit: 3)
  scanBound.run(query: "txt")
  await scanBound.task?.value
  #expect(scanBound.scanned == 3)
  #expect(scanBound.results.count == 3)
  #expect(scanBound.truncated)

  let exact = DeepSearch(
    repository: ListingRepository(keys: keys, pageSize: 2), source: try source(), location: location,
    scanLimit: 4)
  exact.run(query: "txt")
  await exact.task?.value
  #expect(exact.results.count == 4)
  #expect(!exact.truncated)

  let matchBound = DeepSearch(
    repository: ListingRepository(keys: keys, pageSize: 2), source: try source(), location: location,
    matchLimit: 1)
  matchBound.run(query: "txt")
  await matchBound.task?.value
  #expect(matchBound.results.map(\.key) == ["f/a.txt"])
  #expect(matchBound.truncated)
}

// MARK: - StorageScan

@MainActor
@Test func storageScanFlagsTruncationOnlyWhenObjectsRemain() async throws {
  let keys = ["s/1", "s/2", "s/3", "s/4"]
  let location = try S3Location(bucket: "b", prefix: "s/")
  let bounded = StorageScan(
    repository: ListingRepository(keys: keys, pageSize: 2), source: try source(), location: location, limit: 3
  )
  bounded.start()
  await bounded.task?.value
  #expect(bounded.scannedObjects == 3)
  #expect(bounded.summary.objectCount == 3)
  #expect(bounded.truncated)

  let exact = StorageScan(
    repository: ListingRepository(keys: keys, pageSize: 2), source: try source(), location: location, limit: 4
  )
  exact.start()
  await exact.task?.value
  #expect(exact.scannedObjects == 4)
  #expect(!exact.truncated)
}

// MARK: - ImageMetadata

/// A noisy 1600×1200 JPEG larger than `ImageMetadata.prefixLength`, so a prefix read is truncated.
private func noiseJPEG(embedThumbnail: Bool, properties extra: [CFString: Any] = [:]) throws -> Data {
  let width = 1600
  let height = 1200
  var state: UInt32 = 1
  var pixels = [UInt32](repeating: 0, count: width * height)
  for index in pixels.indices {
    state = state &* 1_664_525 &+ 1_013_904_223
    pixels[index] = state | 0xFF00_0000
  }
  let image = try #require(
    pixels.withUnsafeMutableBytes { bytes in
      CGContext(
        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    })
  let jpeg = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
  var properties = extra
  properties[kCGImageDestinationEmbedThumbnail] = embedThumbnail
  properties[kCGImageDestinationLossyCompressionQuality] = 0.9
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  #expect(CGImageDestinationFinalize(destination))
  let data = jpeg as Data
  #expect(Int64(data.count) > ImageMetadata.prefixLength)
  return data
}

@Test func imageMetadataReadsEmbeddedThumbnailAndEXIFFromAPrefix() throws {
  let width = 1600
  let height = 1200
  let data = try noiseJPEG(
    embedThumbnail: true,
    properties: [
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Box 1"],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
        kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
        kCGImagePropertyExifISOSpeedRatings: [200],
        kCGImagePropertyExifExposureTime: 0.004,
      ],
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 33.9, kCGImagePropertyGPSLatitudeRef: "S",
        kCGImagePropertyGPSLongitude: 18.4, kCGImagePropertyGPSLongitudeRef: "E",
      ],
    ])

  let (thumbnail, info) = ImageMetadata.read(data.prefix(Int(ImageMetadata.prefixLength)))

  let thumb = try #require(thumbnail)
  #expect(max(thumb.width, thumb.height) <= 520)
  #expect(thumb.width * height == thumb.height * width)
  #expect(info?.pixelWidth == width)
  #expect(info?.make == "Acme")
  #expect(info?.model == "Box 1")
  #expect(info?.dateTaken == Date(timeIntervalSince1970: 1_714_972_089))
  #expect(info?.exposure == "1/250 s · ISO 200")
  #expect(info?.latitude == -33.9)
  #expect(info?.longitude == 18.4)
}

/// ImageIO decodes a truncated JPEG without an embedded thumbnail into a mostly grey image; that must
/// not be shown as a thumbnail.
@Test func imageMetadataIgnoresDecodesOfATruncatedMainImage() throws {
  let data = try noiseJPEG(embedThumbnail: false)

  #expect(ImageMetadata.read(data.prefix(Int(ImageMetadata.prefixLength))).thumbnail == nil)
}

@Test func exposureUsesFractionsOnlyForFastOrExactShutterSpeeds() {
  #expect(ImageMetadata.exposureTime(0.004) == "1/250 s")
  #expect(ImageMetadata.exposureTime(0.25) == "1/4 s")
  #expect(ImageMetadata.exposureTime(0.5) == "1/2 s")
  #expect(ImageMetadata.exposureTime(1.0 / 3) == "1/3 s")
  #expect(ImageMetadata.exposureTime(0.8) == "\(0.8.formatted()) s")
  #expect(ImageMetadata.exposureTime(0.6) == "\(0.6.formatted()) s")
  #expect(ImageMetadata.exposureTime(2) == "\(2.0.formatted()) s")
}
