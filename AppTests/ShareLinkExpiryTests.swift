import Foundation
import OpenBucketCore
import Testing

@testable import OpenBucket

@Test func shareLinkLifetimeWarnsAboutTemporaryCredentials() throws {
  let now = Date(timeIntervalSince1970: 1_000_000)
  let longLived = S3Credentials(accessKeyID: "a", secretAccessKey: "s")
  let tokenOnly = S3Credentials(accessKeyID: "a", secretAccessKey: "s", sessionToken: "t")
  let soon = S3Credentials(
    accessKeyID: "a", secretAccessKey: "s", sessionToken: "t", expiration: now + 600.5)
  let gone = S3Credentials(accessKeyID: "a", secretAccessKey: "s", sessionToken: "t", expiration: now + 30)

  let full = try #require(ShareLinkExpiry.day.lifetime(signedWith: longLived, now: now))
  #expect(full.seconds == 86_400 && full.warning == nil)

  let unknownEnd = try #require(ShareLinkExpiry.day.lifetime(signedWith: tokenOnly, now: now))
  #expect(unknownEnd.seconds == 86_400 && unknownEnd.warning != nil)

  let shortened = try #require(ShareLinkExpiry.hour.lifetime(signedWith: soon, now: now))
  #expect(shortened.seconds == 600 && shortened.warning != nil)

  let fits = try #require(ShareLinkExpiry.fifteenMinutes.lifetime(signedWith: soon, now: now - 600))
  #expect(fits.seconds == 900 && fits.warning == nil)

  #expect(ShareLinkExpiry.day.lifetime(signedWith: gone, now: now) == nil)
}
