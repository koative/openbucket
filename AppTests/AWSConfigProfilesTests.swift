import Foundation
import Testing

@testable import OpenBucket

private func write(_ text: String, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try text.write(to: url, atomically: true, encoding: .utf8)
}

@Test func awsConfigProfilesMergeFilesAndDetectSSO() throws {
  let home = scratchDirectory()
  defer { try? FileManager.default.removeItem(at: home) }
  try write(
    """
    [profile work]
    sso_session = corp
    region = us-east-1

    [default]
    region = eu-west-1

    [profile legacy]
    sso_start_url = https://legacy.awsapps.com/start

    [sso-session corp]
    sso_start_url = https://corp.awsapps.com/start

    [services local]
    s3 =
      endpoint_url = http://localhost:9000
    """, to: home.appendingPathComponent(".aws/config"))
  try write(
    """
    [default]
    aws_access_key_id = AKIDEXAMPLE
    aws_secret_access_key = do-not-return

    [static]
    aws_access_key_id = AKIDEXAMPLE
    region = ap-south-1
    """, to: home.appendingPathComponent(".aws/credentials"))

  let entries = AWSConfigProfiles.load(home: home)

  #expect(
    entries == [
      .init(name: "default", region: "eu-west-1", usesSSO: false),
      .init(name: "legacy", region: nil, usesSSO: true),
      .init(name: "static", region: "ap-south-1", usesSSO: false),
      .init(name: "work", region: "us-east-1", usesSSO: true),
    ])
}
