import Foundation
import OpenBucketCore
import Security

enum CredentialStoreError: Error, Equatable {
  case notFound
  case invalidData
  case keychain(OSStatus)
}

actor KeychainCredentialStore: CredentialStore {
  private struct Record: Codable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?

    init(_ credentials: S3Credentials) {
      accessKeyID = credentials.accessKeyID
      secretAccessKey = credentials.secretAccessKey
      sessionToken = credentials.sessionToken
    }

    var credentials: S3Credentials {
      S3Credentials(
        accessKeyID: accessKeyID,
        secretAccessKey: secretAccessKey,
        sessionToken: sessionToken
      )
    }
  }

  private let service: String

  init(service: String = "dev.openbucket.credentials") {
    self.service = service
  }

  func save(_ credentials: S3Credentials, reference: UUID) throws {
    let data = try JSONEncoder().encode(Record(credentials))
    var attributes = itemQuery(reference: reference)
    attributes[kSecValueData as String] = data
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = [kSecValueData as String: data] as CFDictionary
      let updateStatus = SecItemUpdate(itemQuery(reference: reference) as CFDictionary, update)
      guard updateStatus == errSecSuccess else { throw CredentialStoreError.keychain(updateStatus) }
    } else if status != errSecSuccess {
      throw CredentialStoreError.keychain(status)
    }
  }

  func load(reference: UUID) throws -> S3Credentials {
    var query = itemQuery(reference: reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { throw CredentialStoreError.notFound }
    guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    guard let data = result as? Data,
      let record = try? JSONDecoder().decode(Record.self, from: data)
    else { throw CredentialStoreError.invalidData }
    return record.credentials
  }

  func delete(reference: UUID) throws {
    let status = SecItemDelete(itemQuery(reference: reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.keychain(status)
    }
  }

  /// Login Keychain only: builds have no entitlement for the data-protection Keychain.
  private func itemQuery(reference: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference.uuidString,
    ]
  }
}
