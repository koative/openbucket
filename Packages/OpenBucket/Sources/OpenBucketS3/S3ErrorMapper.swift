import AsyncHTTPClient
import Foundation
import Network
import OpenBucketCore
import SotoCore

/// Maps SDK errors to user-facing failures. `technicalDetail` never echoes service messages,
/// response bodies, or file paths. Local file failures arrive here already mapped by the adapter.
enum S3ErrorMapper {
  private static let unreachable = "The S3 endpoint could not be reached."
  private static let generic = "The S3 request failed. Check the connection settings and service response."
  private static let denied = "Access to this S3 operation was denied."
  private static let writeDenied = "This connection's credentials can't change objects here."
  static let objectMissing = "This object no longer exists. Refresh the folder."
  private static let busy = "The S3 service is busy or unavailable. Try again shortly."
  private static let unsupported = "This S3 service does not support the requested operation."

  /// `writing` words access denial as a missing write permission.
  static func map(_ error: Error, writing: Bool = false) -> S3Failure {
    if let existing = error as? S3Failure { return existing }
    if let serviceError = error as? any AWSErrorType {
      return serviceFailure(
        code: serviceError.errorCode, status: serviceError.context?.responseCode.code, writing: writing,
        bucketRegion: serviceError.context?.headers.first(name: "x-amz-bucket-region"))
    }
    // Soto throws AWSRawError when it can't parse the error body, e.g. an HTML page from a proxy.
    if let rawError = error as? AWSRawError {
      return serviceFailure(
        code: nil, status: rawError.context.responseCode.code, writing: writing,
        bucketRegion: rawError.context.headers.first(name: "x-amz-bucket-region"))
    }
    if error is HTTPClient.NWTLSError {
      return S3Failure(
        category: .tls, message: "TLS verification failed. Check the endpoint certificate.",
        technicalDetail: "SDK error: NWTLSError")
    }
    // DNS failures arrive as Network's own NWError; AsyncHTTPClient only wraps its TLS and POSIX cases.
    if error is HTTPClient.NWPOSIXError || error is NWError {
      return S3Failure(
        category: .network, message: unreachable, technicalDetail: "SDK error: \(type(of: error))")
    }
    if let httpError = error as? HTTPClientError {
      return httpError == .deadlineExceeded
        ? S3Failure(
          category: .timeout, message: "The S3 endpoint didn't respond in time.",
          technicalDetail: "SDK error: HTTPClientError")
        : S3Failure(category: .network, message: unreachable, technicalDetail: "SDK error: HTTPClientError")
    }
    // ponytail: NIOCore isn't a direct dependency, so ChannelError is matched by name.
    let name = String(describing: type(of: error))
    if name == "ChannelError" {
      return S3Failure(category: .network, message: unreachable, technicalDetail: "SDK error: ChannelError")
    }
    return S3Failure(category: .unknown, message: generic, technicalDetail: "SDK error: \(name)")
  }

  /// Classifies by S3 error code, falling back on the HTTP status when the code is missing or unknown.
  /// `bucketRegion` is Amazon's `x-amz-bucket-region`, which names the right region for a wrong-region request.
  static func serviceFailure(
    code: String?, status: UInt?, writing: Bool = false, bucketRegion: String? = nil
  ) -> S3Failure {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
    let safeCode = code.map {
      $0.count <= 64 && $0.unicodeScalars.allSatisfy(allowed.contains) ? $0 : "Unrecognized"
    }
    let detail = safeCode.map { "S3 code: \($0)" } ?? "HTTP status: \(status ?? 0)"
    let (category, message): (S3Failure.Category, String) =
      switch code ?? "" {
      case "AccessDenied", "AllAccessDisabled":
        (.authorization, writing ? writeDenied : denied)
      case "InvalidAccessKeyId", "ExpiredToken", "InvalidToken":
        (.authentication, "S3 rejected these credentials.")
      case "SignatureDoesNotMatch":
        (
          .authentication,
          "The S3 request signature was rejected. Check the secret, region, and endpoint path."
        )
      case "RequestTimeTooSkewed", "RequestExpired":
        (.authentication, "S3 rejected the request time. Check this Mac's date and time.")
      case "AuthorizationHeaderMalformed", "PermanentRedirect", "IncorrectEndpoint":
        (.regionOrEndpoint, "Check the bucket, region, and endpoint address.")
      case "NoSuchKey", "NoSuchVersion":
        (.notFound, objectMissing)
      case "InvalidObjectState":
        (.service, "This object is archived. Restore it in S3 before reading or copying it.")
      case "NoSuchUpload":
        (.notFound, "The upload was interrupted on the server. Try again.")
      case "EntityTooLarge":
        (.service, "The file is larger than this S3 service accepts.")
      case "InvalidObjectName", "KeyTooLong":
        (
          .unknown,
          "The S3 service doesn't accept this name. Try a shorter name with fewer special characters."
        )
      case "NoSuchBucket":
        (.notFound, "This bucket doesn't exist or isn't visible to these credentials.")
      case "SlowDown", "ServiceUnavailable", "InternalError":
        (.service, busy)
      case "NotImplemented", "UnsupportedOperation":
        (.unsupportedOperation, unsupported)
      default:
        switch status ?? 0 {
        case 401, 403: (.authorization, writing ? writeDenied : denied)
        // Redirects aren't followed (they break the signature); S3 sends a bare 301 for a HEAD in the wrong region.
        case 300..<400: (.regionOrEndpoint, "Check the bucket, region, and endpoint address.")
        // A bare 404 (Soto reports it as "NotFound") usually means a wrong endpoint path or bucket.
        case 404: (.notFound, "The endpoint returned Not Found. Check the endpoint URL and bucket.")
        case 501: (.unsupportedOperation, unsupported)
        case 500..<600: (.service, busy)
        default: (.unknown, generic)
        }
      }
    if category == .regionOrEndpoint, let region = bucketRegion,
      (1...32).contains(region.count),
      region.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
    {
      return S3Failure(
        category: category, message: "This bucket is in \(region). Edit the connection to use that region.",
        technicalDetail: detail)
    }
    return S3Failure(category: category, message: message, technicalDetail: detail)
  }
}
