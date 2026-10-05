import Foundation

public struct S3Failure: Error, Equatable, Sendable {
  public enum Category: Sendable {
    case network
    case tls
    case timeout
    case authentication
    case authorization
    case regionOrEndpoint
    case notFound
    case service
    case unsupportedOperation
    case missingCredentials
    case localFile
    case unknown
  }

  public let category: Category
  public let message: String
  public let technicalDetail: String?

  public init(category: Category, message: String, technicalDetail: String? = nil) {
    self.category = category
    self.message = message
    self.technicalDetail = technicalDetail
  }
}
