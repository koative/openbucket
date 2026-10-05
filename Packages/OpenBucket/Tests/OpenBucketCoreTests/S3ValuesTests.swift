import Foundation
import Testing

@testable import OpenBucketCore

@Test func parsesLocationWithoutChangingKeyPrefix() throws {
  let location = try S3Location("s3://photos//2026/trip/")

  #expect(location.bucket == "photos")
  #expect(location.prefix == "/2026/trip/")
}

@Test func retainsEndpointPath() throws {
  let endpoint = try S3Endpoint("https://storage.example.com/s3/")

  #expect(endpoint.absoluteString == "https://storage.example.com/s3/")
}

@Test func rejectsEndpointQuery() {
  #expect(throws: S3Endpoint.ValidationError.self) {
    try S3Endpoint("https://storage.example.com/s3/?token=secret")
  }
}

@Test func rejectsEndpointPathThatTheSDKWouldRewrite() {
  #expect(throws: S3Endpoint.ValidationError.self) {
    try S3Endpoint("https://storage.example.com/s3%2Fgateway")
  }
}

@Test func objectIdentityKeepsDistinctUTF8Keys() {
  let composed = ObjectSummary(key: "\u{00E9}.txt", size: 1, lastModified: nil, eTag: nil)
  let decomposed = ObjectSummary(key: "e\u{0301}.txt", size: 1, lastModified: nil, eTag: nil)
  #expect(composed.id != decomposed.id)
  #expect(composed != decomposed)
  #expect(Set([composed, decomposed]).count == 2)
}

@Test func locationEqualityKeepsDistinctUTF8Prefixes() throws {
  let composed = try S3Location(bucket: "photos", prefix: "\u{00E9}/")
  let decomposed = try S3Location(bucket: "photos", prefix: "e\u{0301}/")
  #expect(composed != decomposed)
  #expect(Set([composed, decomposed, try S3Location(bucket: "photos", prefix: "\u{00E9}/")]).count == 2)
}

@Test func recognizesAmazonHosts() throws {
  #expect(try S3Endpoint("https://S3.US-EAST-1.AMAZONAWS.COM").isAmazon)
  #expect(try S3Endpoint("https://s3.cn-north-1.amazonaws.com.cn").isAmazon)
  #expect(try S3Endpoint("https://amazonaws.com").isAmazon)
  #expect(try !S3Endpoint("https://notamazonaws.com").isAmazon)
  #expect(try !S3Endpoint("https://amazonaws.com.example.org").isAmazon)
}

@Test func addressingRulesMatchWhatSotoSends() throws {
  func problem(_ endpoint: String, _ style: AddressingStyle, _ bucket: String?) throws -> Bool {
    try ConnectionProfile(name: "Test", endpoint: S3Endpoint(endpoint), region: "r", addressingStyle: style)
      .addressingProblem(bucket: bucket) != nil
  }
  let amazon = "https://s3.us-east-1.amazonaws.com"
  #expect(try problem(amazon, .path, "photos"))
  #expect(try !problem(amazon, .path, "my.photos"))
  #expect(try !problem(amazon, .path, nil))
  #expect(try !problem("https://garage.example.com", .path, "photos"))
  #expect(try problem("https://gateway.example.com/s3", .virtualHost, nil))
  #expect(try !problem("https://gateway.example.com/", .virtualHost, ""))
  #expect(try problem("https://gateway.example.com", .virtualHost, "my.photos"))
  #expect(try !problem("https://gateway.example.com/s3", .automatic, "my.photos"))
}

@Test func parsesSupportedLinks() throws {
  let cases: [(String, String, String)] = [
    ("  s3://photos/trip/a.jpg \n", "photos", "trip/a.jpg"),
    ("s3://photos", "photos", ""),
    (
      "https://s3.console.aws.amazon.com/s3/buckets/photos?region=us-east-1&prefix=trip/2026/&showversions=false",
      "photos", "trip/2026/"
    ),
    ("https://s3.console.aws.amazon.com/s3/buckets/photos", "photos", ""),
    (
      "https://us-east-1.console.aws.amazon.com/s3/object/photos?region=us-east-1&prefix=trip/a%20b%2Bc.jpg",
      "photos", "trip/a b+c.jpg"
    ),
    ("https://photos.s3.amazonaws.com/trip/a%20b.jpg", "photos", "trip/a b.jpg"),
    ("https://photos.s3.amazonaws.com/trip/a+b%2Bc.jpg", "photos", "trip/a b+c.jpg"),
    ("https://s3-logs.s3.us-east-1.amazonaws.com/2026/a.log", "s3-logs", "2026/a.log"),
    ("s3://photos/trip/a+b.jpg", "photos", "trip/a+b.jpg"),
    ("https://photos.s3.eu-west-1.amazonaws.com/trip/a.jpg", "photos", "trip/a.jpg"),
    ("https://photos.s3-eu-west-1.amazonaws.com/trip/a.jpg", "photos", "trip/a.jpg"),
    ("https://my.photos.s3.us-east-2.amazonaws.com/a.jpg", "my.photos", "a.jpg"),
    ("https://photos.s3.cn-north-1.amazonaws.com.cn/a", "photos", "a"),
    ("https://s3.eu-west-1.amazonaws.com/photos/trip/%C3%A9%2Fx.jpg", "photos", "trip/\u{00E9}/x.jpg"),
    ("https://s3.amazonaws.com/photos", "photos", ""),
  ]
  for (link, bucket, prefix) in cases {
    let location = try #require(S3Location(link: link), "\(link)")
    #expect(location.bucket == bucket, "\(link)")
    #expect(location.prefix.utf8.elementsEqual(prefix.utf8), "\(link)")
  }
  let junk = [
    "", "photos/trip", "s3://", "https://example.com/photos/a", "https://s3.amazonaws.com/",
    "https://s3.console.aws.amazon.com/s3/home", "ftp://photos.s3.amazonaws.com/a",
    "https://amazonaws.com.example.org/photos/a",
  ]
  for link in junk { #expect(S3Location(link: link) == nil, "\(link)") }
}

@Test func parentClimbsOneFolder() throws {
  func parent(_ prefix: String) throws -> String? {
    try S3Location(bucket: "b", prefix: prefix).parent?.prefix
  }
  #expect(try parent("a/b/c.txt") == "a/b/")
  #expect(try parent("a/b/") == "a/")
  #expect(try parent("a") == "")
  #expect(try parent("a//") == "a/")
  #expect(try parent("") == nil)
}

@Test func decodesProfilesSavedBeforeCredentialSourceFavoritesAndAllowsChanges() throws {
  let old = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","endpoint":"https://s3.us-east-1.amazonaws.com",
     "region":"us-east-1","addressingStyle":"automatic","startingPrefix":"",
     "credentialReference":"7F9619FF-8B86-D011-B42D-00C04FC964FF"}
    """
  let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(old.utf8))
  #expect(profile.credentialSource == .keychain)
  #expect(profile.favorites.isEmpty)
  #expect(!profile.allowsChanges)

  var updated = profile
  updated.credentialSource = .awsProfile("work")
  updated.favorites = [try S3Location("s3://photos/trip/"), try S3Location("s3://photos")]
  updated.allowsChanges = true
  let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(updated))
  #expect(decoded == updated)
}

@Test func versionIdentityKeepsDistinctUTF8Keys() {
  func version(_ key: String) -> ObjectVersion {
    ObjectVersion(
      key: key, versionID: "null", isLatest: true, isDeleteMarker: false, lastModified: nil, size: 1,
      eTag: nil,
      storageClass: nil)
  }
  #expect(version("\u{00E9}").id != version("e\u{0301}").id)
  #expect(version("a/b").id != version("a%2Fb").id)
}
