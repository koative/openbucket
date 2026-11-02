import Foundation

/// Stores S3 credentials separately from serializable connection profiles.
public protocol CredentialStore: Sendable {
  func save(_ credentials: S3Credentials, reference: UUID) async throws
  func load(reference: UUID) async throws -> S3Credentials
  func delete(reference: UUID) async throws
}
