import Accessibility
import OpenBucketCore
import SwiftUI

struct ConnectionEditor: View {
  @Environment(\.dismiss) private var dismiss
  let model: AppModel
  let existing: ConnectionProfile?

  @State private var name: String
  @State private var endpoint: String
  @State private var region: String
  @State private var addressingStyle: AddressingStyle
  @State private var bucket: String
  @State private var startingPrefix: String
  @State private var accessKeyID = ""
  @State private var secretAccessKey = ""
  @State private var sessionToken = ""
  @State private var usesAWSProfile: Bool
  /// Selected profile name; empty until one is chosen.
  @State private var awsProfile: String
  @State private var allowsChanges: Bool
  @State private var awsProfiles: [AWSConfigProfiles.Entry] = []
  /// What `prefill` last wrote; it keeps replacing these while the fields still hold them.
  @State private var prefilledRegion: String?
  @State private var prefilledEndpoint: String?
  @State private var status: Status?
  /// Fields whose inline problem may show; everything shows after a Test or Save attempt.
  @State private var touched: Set<Field> = []
  @State private var submitted = false

  init(model: AppModel, existing: ConnectionProfile?) {
    self.model = model
    self.existing = existing
    _name = State(initialValue: existing?.name ?? "")
    _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "https://")
    _region = State(initialValue: existing?.region ?? Self.defaultRegion)
    _addressingStyle = State(initialValue: existing?.addressingStyle ?? .automatic)
    _bucket = State(initialValue: existing?.knownBucket ?? "")
    _startingPrefix = State(initialValue: existing?.startingPrefix ?? "")
    _allowsChanges = State(initialValue: existing?.allowsChanges ?? false)
    if case .awsProfile(let name)? = existing?.credentialSource {
      _usesAWSProfile = State(initialValue: true)
      _awsProfile = State(initialValue: name)
    } else {
      _usesAWSProfile = State(initialValue: false)
      _awsProfile = State(initialValue: "")
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(existing == nil ? "New Connection" : "Edit Connection")
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 20)

      Form {
        Section("Connection") {
          TextField("Name", text: $name, prompt: Text("Required"))
            .onChange(of: name) { touched.insert(.name) }
          message(.name)
          TextField("Endpoint URL", text: $endpoint)
            .textContentType(.URL)
            .onChange(of: endpoint) { touched.formUnion([.endpoint, .addressing]) }
          message(.endpoint)
          TextField("Region", text: $region)
            .onChange(of: region) { touched.insert(.region) }
          message(.region)
          Picker("Bucket addressing", selection: $addressingStyle) {
            Text("Automatic").tag(AddressingStyle.automatic)
            Text("Path style").tag(AddressingStyle.path)
            Text("Virtual host").tag(AddressingStyle.virtualHost)
          }
          .onChange(of: addressingStyle) { touched.insert(.addressing) }
          message(.addressing)
        }

        Section("Starting location") {
          TextField(text: $bucket, prompt: Text("Optional")) {
            Text("Known bucket")
            Text("Connects without permission to list every bucket.")
          }
          .onChange(of: bucket) { touched.formUnion([.bucket, .addressing]) }
          message(.bucket)
          TextField(text: $startingPrefix, prompt: Text("Optional")) {
            Text("Starting folder")
            Text("A folder inside the bucket, such as photos/2026/.")
          }
        }

        Section {
          Toggle(isOn: $allowsChanges) {
            Text("Allow changes")
            Text("Upload, rename, move, delete and edit files. Off keeps this connection read-only.")
          }
        }

        Section {
          Picker("Sign in with", selection: $usesAWSProfile) {
            Text("Access keys").tag(false)
            Text("AWS profile").tag(true)
          }
          .pickerStyle(.segmented)
          if usesAWSProfile {
            if awsProfiles.isEmpty {
              Label("No AWS profiles found.", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
            } else {
              Picker("Profile", selection: $awsProfile) {
                Text("None").tag("")
                ForEach(awsProfiles) { entry in
                  Text(entry.usesSSO ? "\(entry.name) (IAM Identity Center)" : entry.name).tag(entry.name)
                }
                // A saved profile that's gone from the config files stays visible instead of vanishing.
                if !awsProfile.isEmpty, !awsProfiles.contains(where: { $0.name == awsProfile }) {
                  Text("\(awsProfile) (not found)").tag(awsProfile)
                }
              }
              .onChange(of: awsProfile) {
                touched.insert(.awsProfile)
                prefill(from: awsProfile)
              }
            }
            message(.awsProfile)
          } else {
            TextField("Access key ID", text: $accessKeyID, prompt: Text("Required"))
              .onChange(of: accessKeyID) { touched.insert(.accessKeyID) }
            message(.accessKeyID)
            SecureField("Secret access key", text: $secretAccessKey, prompt: Text("Required"))
              .onChange(of: secretAccessKey) { touched.insert(.secretAccessKey) }
            message(.secretAccessKey)
            SecureField("Session token", text: $sessionToken, prompt: Text("Optional"))
          }
        } header: {
          Text("Credentials")
        } footer: {
          if usesAWSProfile {
            HStack(alignment: .firstTextBaseline) {
              Text("Uses ~/.aws/config. For IAM Identity Center, sign in with `aws sso login` first.")
                .foregroundStyle(.secondary)
              Spacer()
              Button("Refresh") { awsProfiles = AWSConfigProfiles.load() }
            }
          } else {
            Text("Credentials are saved in this Mac’s Keychain.")
              .foregroundStyle(.secondary)
          }
        }

        Section {
          if let problem = draft?.addressingProblem(bucket: bucket.trimmed) {
            Label {
              Text(problem)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
          } else {
            Text(requestShape)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
          }
        } header: {
          Text("Request preview")
        } footer: {
          Text("The endpoint path and the starting folder are separate settings.")
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Button("Test Connection") { runTest() }
          .disabled(isWorking || !isComplete)
        statusView
        // The Spacer keeps Cancel and the primary button trailing whatever the status shows.
        Spacer(minLength: 12)
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(existing == nil ? "Add Connection" : "Save Changes") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(isWorking || !isComplete)
      }
      .padding()
    }
    .frame(minWidth: 600, minHeight: 610)
    .task {
      awsProfiles = AWSConfigProfiles.load()
      // Only Keychain keys are prefilled; resolving an AWS profile here could start an SSO refresh.
      guard let existing, existing.credentialSource == .keychain else { return }
      do {
        let credentials = try await model.credentials(for: existing)
        accessKeyID = credentials.accessKeyID
        secretAccessKey = credentials.secretAccessKey
        sessionToken = credentials.sessionToken ?? ""
      } catch {
        report(.failed(AppModel.failure(for: error).message))
      }
    }
  }

  private static let defaultRegion = "us-east-1"

  /// Fills region and endpoint from the chosen AWS profile unless the user already set them.
  private func prefill(from name: String) {
    guard let entry = awsProfiles.first(where: { $0.name == name }) else { return }
    let currentRegion = region.trimmed
    if let profileRegion = entry.region,
      currentRegion.isEmpty || currentRegion == Self.defaultRegion || currentRegion == prefilledRegion
    {
      region = profileRegion
      prefilledRegion = profileRegion
    }
    let current = endpoint.trimmed
    if current.isEmpty || current == "https://" || current == prefilledEndpoint, !region.trimmed.isEmpty {
      endpoint = "https://s3.\(region.trimmed).amazonaws.com"
      prefilledEndpoint = endpoint
    }
  }

  @ViewBuilder private var statusView: some View {
    switch status {
    case .working(let text)?:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(text)
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
    case .succeeded(let text)?:
      // Colour stays on the icon; the text keeps body contrast.
      Label {
        Text(text)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .lineLimit(3)
      .help(text)
    case .failed(let text)?:
      Label {
        Text(text)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
      }
      .lineLimit(3)
      .help(text)
    case nil:
      EmptyView()
    }
  }

  /// Inline problem under a field, hidden until the field is edited or a submit is attempted.
  @ViewBuilder private func message(_ field: Field) -> some View {
    if submitted || touched.contains(field), let text = problem(field) {
      Label {
        Text(text).foregroundStyle(.secondary)
      } icon: {
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
      }
      .font(.callout)
    }
  }

  private func problem(_ field: Field) -> String? {
    switch field {
    case .name:
      return name.trimmed.isEmpty ? "Enter a name for this connection." : nil
    case .endpoint:
      return endpointProblem
    case .region:
      return region.trimmed.isEmpty ? "Enter a region, such as us-east-1." : nil
    case .addressing:
      return draft?.addressingProblem(bucket: bucket.trimmed)
    case .bucket:
      let bucketName = bucket.trimmed
      guard !bucketName.isEmpty, (try? S3Location(bucket: bucketName)) == nil else { return nil }
      return "Enter only the bucket name, without s3:// or slashes."
    case .accessKeyID:
      return !usesAWSProfile && accessKeyID.trimmed.isEmpty ? "Enter an access key ID." : nil
    case .secretAccessKey:
      return !usesAWSProfile && secretAccessKey.trimmed.isEmpty ? "Enter a secret access key." : nil
    case .awsProfile:
      return usesAWSProfile && awsProfile.isEmpty ? "Choose an AWS profile." : nil
    }
  }

  private var endpointProblem: String? {
    let text = endpoint.trimmed
    if text.isEmpty { return "Enter an endpoint URL." }
    do {
      _ = try S3Endpoint(text)
      return nil
    } catch S3Endpoint.ValidationError.unsupportedScheme {
      return "The endpoint URL must start with https:// or http://."
    } catch S3Endpoint.ValidationError.missingHost {
      return "Add a host name, such as https://s3.example.com."
    } catch S3Endpoint.ValidationError.userInfoNotAllowed {
      return "Remove the user name and password from the URL. Enter credentials below."
    } catch S3Endpoint.ValidationError.queryOrFragmentNotAllowed {
      return "Remove the query (?…) or fragment (#…) from the URL."
    } catch S3Endpoint.ValidationError.encodedPathNotSupported {
      return "Encoded characters (%) in the endpoint path aren’t supported."
    } catch {
      return "Enter a valid URL, such as https://s3.example.com."
    }
  }

  /// Required fields are filled; finer validation runs on submit and inline.
  private var isComplete: Bool {
    let credentials = usesAWSProfile ? [awsProfile] : [accessKeyID, secretAccessKey]
    return ([name, endpoint, region] + credentials).allSatisfy { !$0.trimmed.isEmpty }
  }

  private var isWorking: Bool {
    if case .working? = status { return true }
    return false
  }

  /// The profile as entered, or nil while the endpoint doesn't parse.
  private var draft: ConnectionProfile? {
    guard let endpoint = try? S3Endpoint(endpoint.trimmed) else { return nil }
    return ConnectionProfile(
      id: existing?.id ?? UUID(),
      name: name.trimmed,
      endpoint: endpoint,
      region: region.trimmed,
      addressingStyle: addressingStyle,
      knownBucket: bucket.trimmed.nilIfEmpty,
      startingPrefix: startingPrefix,
      credentialReference: existing?.credentialReference ?? UUID(),
      credentialSource: usesAWSProfile ? .awsProfile(awsProfile) : .keychain,
      // Live favorites, so saving doesn't drop ones added while the editor was open.
      favorites: model.profiles.first { $0.id == existing?.id }?.favorites ?? [],
      allowsChanges: allowsChanges
    )
  }

  /// Shape preview for a draft without an addressing problem.
  private var requestShape: String {
    guard let profile = draft, let host = profile.endpoint.url.host else {
      return "Enter an endpoint URL to preview the request."
    }
    let path =
      URLComponents(url: profile.endpoint.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    let basePath = path.hasSuffix("/") ? String(path.dropLast()) : path
    let bucketName = profile.knownBucket ?? "<bucket>"
    switch addressingStyle {
    case .automatic:
      if profile.endpoint.isAmazon {
        return "Amazon endpoint selects virtual-host addressing for standard buckets."
      }
      return "Custom endpoint uses path style; endpoint path: \(basePath.isEmpty ? "/" : basePath)"
    case .path:
      return "\(host)\(basePath)/\(bucketName)/<object-key>"
    case .virtualHost:
      return "\(bucketName).\(host)/<object-key>"
    }
  }

  /// Marks every field for display and returns the values only when nothing is wrong.
  /// Credentials are nil for an AWS profile, which resolves them itself.
  private func validated() -> (ConnectionProfile, S3Credentials?)? {
    submitted = true
    guard Field.allCases.allSatisfy({ problem($0) == nil }), let profile = draft else {
      report(.failed("Fix the fields marked in red."))
      return nil
    }
    guard !usesAWSProfile else { return (profile, nil) }
    let credentials = S3Credentials(
      accessKeyID: accessKeyID.trimmed,
      secretAccessKey: secretAccessKey,
      sessionToken: sessionToken.nilIfEmpty
    )
    return (profile, credentials)
  }

  private func runTest() {
    guard case (let profile, let credentials)? = validated() else { return }
    report(.working("Testing…"))
    Task {
      do {
        let resolved = if let credentials { credentials } else { try await model.credentials(for: profile) }
        report(.succeeded(try await model.test(profile: profile, credentials: resolved)))
      } catch {
        report(.failed(AppModel.failure(for: error).message))
      }
    }
  }

  private func save() {
    guard case (let profile, let credentials)? = validated() else { return }
    report(.working("Saving…"))
    Task {
      do {
        try await model.save(profile, credentials: credentials)
        dismiss()
      } catch {
        report(.failed(AppModel.failure(for: error).message))
      }
    }
  }

  private func report(_ newStatus: Status) {
    status = newStatus
    switch newStatus {
    case .working(let text), .succeeded(let text), .failed(let text):
      AccessibilityNotification.Announcement(text).post()
    }
  }
}

private enum Status {
  case working(String)
  case succeeded(String)
  case failed(String)
}

private enum Field: CaseIterable {
  case name, endpoint, region, addressing, bucket, accessKeyID, secretAccessKey, awsProfile
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
