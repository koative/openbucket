import Foundation
import OpenBucketCore
import Security
import Testing

@testable import OpenBucket

@Test func profileFileContainsNoCredentials() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("openbucket-\(UUID().uuidString)", isDirectory: true)
  let fileURL = directory.appendingPathComponent("profiles.json")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ProfileStore(fileURL: fileURL)
  let profile = ConnectionProfile(
    name: "Garage",
    endpoint: try S3Endpoint("https://s3.example.com/prefix/"),
    region: "garage",
    addressingStyle: .path,
    knownBucket: "photos"
  )

  try await store.save([profile])
  try await store.save([])
  #expect(try await store.load().isEmpty)
  try await store.save([profile])
  let data = try Data(contentsOf: fileURL)
  let text = try #require(String(data: data, encoding: .utf8))

  #expect(text.contains("Garage"))
  #expect(text.contains(profile.credentialReference.uuidString))
  #expect(!text.contains("secretAccessKey"))
  let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
  #expect(attributes[.posixPermissions] as? Int == 0o600)
  let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
  #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
  #expect(try await store.load() == [profile])
}

/// Runs `body` against an isolated Keychain service and always deletes the item afterwards.
private func withKeychainItem(
  _ body: (_ store: KeychainCredentialStore, _ service: String, _ reference: UUID) async throws -> Void
) async throws {
  let service = "dev.openbucket.tests.\(UUID().uuidString)"
  let store = KeychainCredentialStore(service: service)
  let reference = UUID()
  do {
    try await body(store, service, reference)
  } catch {
    try? await store.delete(reference: reference)
    throw error
  }
  try await store.delete(reference: reference)
}

@Test func keychainRoundTripUpdateAndDeletion() async throws {
  try await withKeychainItem { store, _, reference in
    try await store.save(S3Credentials(accessKeyID: "old", secretAccessKey: "old"), reference: reference)
    let credentials = S3Credentials(
      accessKeyID: "test-access-key",
      secretAccessKey: "test-secret-key",
      sessionToken: "test-session-token"
    )
    try await store.save(credentials, reference: reference)
    let loaded = try await store.load(reference: reference)
    #expect(loaded.accessKeyID == credentials.accessKeyID)
    #expect(loaded.secretAccessKey == credentials.secretAccessKey)
    #expect(loaded.sessionToken == credentials.sessionToken)

    try await store.delete(reference: reference)
    await #expect(throws: CredentialStoreError.notFound) { try await store.load(reference: reference) }
  }
}

@Test func existingLoginKeychainCredentialRemainsReadable() async throws {
  try await withKeychainItem { store, service, reference in
    let data = try JSONEncoder().encode(["accessKeyID": "legacy-access", "secretAccessKey": "legacy-secret"])
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference.uuidString,
      kSecValueData as String: data,
    ]
    #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
    let loaded = try await store.load(reference: reference)
    #expect(loaded.accessKeyID == "legacy-access")
    #expect(loaded.secretAccessKey == "legacy-secret")
  }
}
