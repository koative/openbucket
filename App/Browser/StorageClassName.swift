/// The S3 console's names for raw S3 values; copy actions keep the raw value.
enum StorageClassName {
  /// Storage classes; unknown ones (other providers) in sentence case.
  static func display(_ raw: String) -> String {
    switch raw {
    case "STANDARD": "Standard"
    case "REDUCED_REDUNDANCY": "Reduced Redundancy"
    case "STANDARD_IA": "Standard-IA"
    case "ONEZONE_IA": "One Zone-IA"
    case "INTELLIGENT_TIERING": "Intelligent-Tiering"
    case "GLACIER_IR": "Glacier Instant Retrieval"
    case "GLACIER": "Glacier Flexible Retrieval"
    case "DEEP_ARCHIVE": "Glacier Deep Archive"
    case "EXPRESS_ONEZONE": "Express One Zone"
    case "OUTPOSTS": "Outposts"
    case "SNOW": "Snow"
    default: String(raw.prefix(1)) + raw.dropFirst().lowercased().replacingOccurrences(of: "_", with: " ")
    }
  }

  /// `x-amz-server-side-encryption` values; unknown ones as sent.
  static func encryption(_ raw: String) -> String {
    switch raw {
    case "AES256": "SSE-S3 (AES-256)"
    case "aws:kms": "SSE-KMS"
    case "aws:kms:dsse": "DSSE-KMS"
    default: raw
    }
  }
}
