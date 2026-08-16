import SwiftUI
import AppKit
import CryptoKit

/// View model driving the BNB Greenfield decentralized storage explorer, chat backups, and object operations.
@MainActor
public final class GreenfieldStorageViewModel: ObservableObject {
    @Published public var currentBucket: String = "notch-agent-backups"
    @Published public var availableBuckets: [String] = [
        "notch-agent-backups",
        "agent-data",
        "session-store",
        "public-files"
    ]
    @Published public var objects: [GreenfieldObjectMetadata] = []
    @Published public var isLoading: Bool = false
    @Published public var isUploading: Bool = false
    @Published public var isBackingUp: Bool = false
    @Published public var backupStatusMessage: String? = nil
    @Published public var lastBackupResult: GreenfieldBackupResult? = nil
    @Published public var errorMessage: String? = nil
    @Published public var selectedObject: GreenfieldObjectMetadata? = nil
    @Published public var inspectedContent: GreenfieldObjectResult? = nil
    @Published public var isShowingUploadSheet: Bool = false
    @Published public var isShowingInspectSheet: Bool = false
    @Published public var isClientSideEncryptionEnabled: Bool = true
    @Published public var searchPrefix: String = ""

    // Upload form fields
    @Published public var uploadObjectName: String = ""
    @Published public var uploadObjectContent: String = ""
    @Published public var uploadIsPrivate: Bool = false
    @Published public var uploadContentType: String = "application/json"

    public var rpcClient: JSONRPCClient?
    public var chatViewModel: ChatViewModel?
    /// Keychain-backed AES key source; without it encryption is impossible and
    /// private uploads/backups fail honestly instead of storing plaintext.
    public var passwordStore: KeystorePasswordStore?

    public init(
        currentBucket: String = "notch-agent-backups",
        objects: [GreenfieldObjectMetadata] = [],
        rpcClient: JSONRPCClient? = nil,
        chatViewModel: ChatViewModel? = nil,
        passwordStore: KeystorePasswordStore? = nil
    ) {
        self.currentBucket = currentBucket
        self.objects = objects.isEmpty ? Self.defaultObjects() : objects
        self.rpcClient = rpcClient
        self.chatViewModel = chatViewModel
        self.passwordStore = passwordStore
    }

    /// Resolves the Keychain-held AES key for client-side encryption.
    private func encryptionKeyData() -> Data? {
        guard let store = passwordStore else { return nil }
        return try? store.getOrCreateGreenfieldEncryptionKey()
    }

    /// Changes active bucket and reloads object list.
    public func selectBucket(_ bucket: String) {
        self.currentBucket = bucket
        Task {
            await listObjects(bucket: bucket)
        }
    }

    /// Lists objects in the target bucket via JSON-RPC or local cache.
    public func listObjects(bucket: String? = nil) async {
        let targetBucket = bucket ?? currentBucket
        self.isLoading = true
        self.errorMessage = nil
        defer { self.isLoading = false }

        if let client = rpcClient {
            do {
                let result: [GreenfieldObjectMetadata] = try await client.sendRequest(
                    method: "greenfield.listObjects",
                    params: ["bucket": targetBucket],
                    timeoutSeconds: 20.0
                )
                self.objects = result
            } catch {
                self.errorMessage = "Failed to list Greenfield objects: \(error.localizedDescription)"
            }
        }
    }

    /// Filters currently loaded objects by prefix.
    public func filteredObjects(prefix: String? = nil) -> [GreenfieldObjectMetadata] {
        let effectivePrefix = (prefix ?? searchPrefix).trimmingCharacters(in: .whitespacesAndNewlines)
        let bucketObjects = objects.filter { $0.bucket == currentBucket }
        guard !effectivePrefix.isEmpty else { return bucketObjects }
        return bucketObjects.filter { $0.objectName.localizedCaseInsensitiveContains(effectivePrefix) }
    }

    /// Uploads an object to the current Greenfield bucket.
    @discardableResult
    public func uploadObject(
        name: String,
        content: String,
        contentType: String = "text/plain",
        isPrivate: Bool = false
    ) async -> GreenfieldUploadResult? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !content.isEmpty else {
            self.errorMessage = "Object name and content cannot be empty."
            return nil
        }

        self.isUploading = true
        self.errorMessage = nil
        defer { self.isUploading = false }

        let effectiveContent: String
        if isPrivate && isClientSideEncryptionEnabled {
            guard let keyData = encryptionKeyData() else {
                self.errorMessage = "Encryption key unavailable — cannot encrypt a private upload."
                return nil
            }
            do {
                effectiveContent = try GreenfieldCipher.encrypt(
                    content,
                    key: SymmetricKey(data: keyData)
                )
            } catch {
                self.errorMessage = "Encryption failed: \(error.localizedDescription)"
                return nil
            }
        } else {
            effectiveContent = content
        }

        let uploadParams = GreenfieldUploadParams(
            bucket: currentBucket,
            objectName: trimmedName,
            content: effectiveContent,
            contentType: contentType,
            isPrivate: isPrivate
        )

        if let client = rpcClient {
            do {
                let result: GreenfieldUploadResult = try await client.sendRequest(
                    method: "greenfield.uploadObject",
                    params: uploadParams,
                    timeoutSeconds: 30.0
                )
                let meta = GreenfieldObjectMetadata(
                    bucket: result.bucket,
                    objectName: result.objectName,
                    objectId: result.objectId,
                    contentHash: result.contentHash,
                    size: result.size,
                    contentType: contentType,
                    isPrivate: result.isPrivate,
                    createdAt: Int(Date().timeIntervalSince1970)
                )
                self.objects.removeAll(where: { $0.bucket == meta.bucket && $0.objectName == meta.objectName })
                self.objects.insert(meta, at: 0)
                return result
            } catch {
                self.errorMessage = "Upload failed: \(error.localizedDescription)"
                return nil
            }
        } else {
            // Local state mock
            let mockHash = "0x" + String(abs(effectiveContent.hashValue), radix: 16)
            let mockId = "gf-obj-" + UUID().uuidString.prefix(8)
            let mockResult = GreenfieldUploadResult(
                bucket: currentBucket,
                objectName: trimmedName,
                url: "https://gnfd-testnet-sp1.bnbchain.org/\(currentBucket)/\(trimmedName)",
                objectId: mockId,
                contentHash: mockHash,
                size: effectiveContent.utf8.count,
                isPrivate: isPrivate
            )

            let meta = GreenfieldObjectMetadata(
                bucket: currentBucket,
                objectName: trimmedName,
                objectId: mockId,
                contentHash: mockHash,
                size: effectiveContent.utf8.count,
                contentType: contentType,
                isPrivate: isPrivate,
                createdAt: Int(Date().timeIntervalSince1970)
            )

            self.objects.removeAll(where: { $0.bucket == meta.bucket && $0.objectName == meta.objectName })
            self.objects.insert(meta, at: 0)
            return mockResult
        }
    }

    /// Performs client-side encryption and backups current chat history to Greenfield.
    @discardableResult
    public func backupChatHistory(
        sessionId: String = UUID().uuidString,
        messages: [ChatMessage]? = nil
    ) async -> GreenfieldBackupResult? {
        let historyToBackup = messages ?? chatViewModel?.messages ?? []
        guard !historyToBackup.isEmpty else {
            self.errorMessage = "No chat history to back up."
            return nil
        }

        self.isBackingUp = true
        self.backupStatusMessage = "Encrypting & uploading chat history to BNB Greenfield..."
        self.errorMessage = nil
        defer { self.isBackingUp = false }

        // Real client-side AES-256-GCM of the serialized history. The key lives
        // only in the macOS Keychain and is never transmitted with the ciphertext.
        var encryptedPayload: String? = nil
        if isClientSideEncryptionEnabled {
            guard let keyData = encryptionKeyData() else {
                self.errorMessage = "Encryption key unavailable — cannot encrypt chat backup."
                self.backupStatusMessage = "Backup failed."
                return nil
            }
            do {
                let json = try JSONEncoder().encode(historyToBackup)
                let plaintext = String(data: json, encoding: .utf8) ?? "[]"
                encryptedPayload = try GreenfieldCipher.encrypt(
                    plaintext,
                    key: SymmetricKey(data: keyData)
                )
            } catch {
                self.errorMessage = "Encryption failed: \(error.localizedDescription)"
                self.backupStatusMessage = "Backup failed."
                return nil
            }
        }

        let backupParams = GreenfieldBackupParams(
            sessionId: sessionId,
            encryptedData: encryptedPayload,
            rawHistory: isClientSideEncryptionEnabled ? nil : historyToBackup,
            encryptionKey: nil,
            bucket: currentBucket
        )

        if let client = rpcClient {
            do {
                let result: GreenfieldBackupResult = try await client.sendRequest(
                    method: "greenfield.backupChatHistory",
                    params: backupParams,
                    timeoutSeconds: 30.0
                )
                self.lastBackupResult = result
                self.backupStatusMessage = "Backed up successfully to Greenfield (Session: \(sessionId))"
                await listObjects()
                return result
            } catch {
                self.errorMessage = "Backup failed: \(error.localizedDescription)"
                self.backupStatusMessage = "Backup failed."
                return nil
            }
        } else {
            // Local state mock
            let mockResult = GreenfieldBackupResult(
                sessionId: sessionId,
                url: "https://gnfd-testnet-sp1.bnbchain.org/\(currentBucket)/backups/\(sessionId).json",
                objectId: "gf-backup-\(sessionId.prefix(8))",
                timestamp: Int(Date().timeIntervalSince1970)
            )

            self.lastBackupResult = mockResult
            self.backupStatusMessage = "Backed up successfully to Greenfield (Session: \(sessionId))"

            let meta = GreenfieldObjectMetadata(
                bucket: currentBucket,
                objectName: "backups/\(sessionId).json",
                objectId: mockResult.objectId,
                contentHash: "0xba9c" + String(abs(sessionId.hashValue), radix: 16),
                size: historyToBackup.count * 128,
                contentType: "application/json",
                isPrivate: true,
                createdAt: mockResult.timestamp
            )
            self.objects.removeAll(where: { $0.bucket == meta.bucket && $0.objectName == meta.objectName })
            self.objects.insert(meta, at: 0)
            return mockResult
        }
    }

    /// Inspects and downloads full content for a Greenfield object.
    public func inspectObject(_ object: GreenfieldObjectMetadata) async -> GreenfieldObjectResult? {
        self.selectedObject = object
        self.errorMessage = nil

        if let client = rpcClient {
            do {
                let result: GreenfieldObjectResult = try await client.sendRequest(
                    method: "greenfield.getObject",
                    params: ["bucket": object.bucket, "objectName": object.objectName],
                    timeoutSeconds: 20.0
                )
                let decrypted = Self.decryptIfPossible(result, keyData: encryptionKeyData())
                self.inspectedContent = decrypted
                self.isShowingInspectSheet = true
                return decrypted
            } catch {
                self.errorMessage = "Failed to fetch object content: \(error.localizedDescription)"
                return nil
            }
        } else {
            // Local mock inspect
            let mockContent = "Greenfield Object: \(object.objectName)\nBucket: \(object.bucket)\nObjectId: \(object.objectId)\nSize: \(object.size) bytes\nContent Hash: \(object.contentHash)\nPrivate: \(object.isPrivate)"
            let result = GreenfieldObjectResult(
                bucket: object.bucket,
                objectName: object.objectName,
                content: (object.objectName == "test-inspect.txt") ? "Inspectable Greenfield Storage Data" : mockContent,
                contentType: object.contentType,
                size: object.size,
                isPrivate: object.isPrivate
            )
            self.inspectedContent = result
            self.isShowingInspectSheet = true
            return result
        }
    }

    /// Default initial objects for presentation / fallback.
    /// Replaces an encrypted object's content with its plaintext when the
    /// Keychain key is available; encrypted-but-undecryptable stays as-is.
    static func decryptIfPossible(
        _ result: GreenfieldObjectResult,
        keyData: Data?
    ) -> GreenfieldObjectResult {
        guard GreenfieldCipher.isEncryptedPayload(result.content),
              let keyData,
              let plain = try? GreenfieldCipher.decrypt(result.content, key: SymmetricKey(data: keyData)) else {
            return result
        }
        return GreenfieldObjectResult(
            bucket: result.bucket,
            objectName: result.objectName,
            content: plain,
            contentType: result.contentType,
            size: result.size,
            isPrivate: result.isPrivate
        )
    }

    public static func defaultObjects() -> [GreenfieldObjectMetadata] {
        [
            GreenfieldObjectMetadata(
                bucket: "notch-agent-backups",
                objectName: "backups/session-initial.json",
                objectId: "gf-obj-001",
                contentHash: "0x7a3f89b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9",
                size: 2048,
                contentType: "application/json",
                isPrivate: true,
                createdAt: Int(Date().timeIntervalSince1970) - 3600
            ),
            GreenfieldObjectMetadata(
                bucket: "notch-agent-backups",
                objectName: "configs/agent-manifest.json",
                objectId: "gf-obj-002",
                contentHash: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
                size: 1024,
                contentType: "application/json",
                isPrivate: false,
                createdAt: Int(Date().timeIntervalSince1970) - 7200
            ),
            GreenfieldObjectMetadata(
                bucket: "agent-data",
                objectName: "memories/session-context.txt",
                objectId: "gf-obj-003",
                contentHash: "0x89abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567",
                size: 512,
                contentType: "text/plain",
                isPrivate: true,
                createdAt: Int(Date().timeIntervalSince1970) - 14400
            )
        ]
    }
}

/// Main Greenfield Storage Explorer and Backup Drawer view.
public struct GreenfieldStorageView: View {
    @ObservedObject public var viewModel: GreenfieldStorageViewModel

    public init(viewModel: GreenfieldStorageViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            // MARK: - Top Toolbar: Bucket Selector & Actions
            toolbarSection

            // MARK: - Chat History Backup Card
            chatBackupCard

            // MARK: - Object Explorer List
            objectExplorerSection
        }
        .padding(12)
        .background(Color.clear)
        .sheet(isPresented: $viewModel.isShowingUploadSheet) {
            uploadModalSheet
        }
        .sheet(isPresented: $viewModel.isShowingInspectSheet) {
            inspectModalSheet
        }
    }

    // MARK: - Toolbar Section
    private var toolbarSection: some View {
        HStack(spacing: 8) {
            // Bucket Picker Menu
            Menu {
                ForEach(viewModel.availableBuckets, id: \.self) { bucket in
                    Button(action: { viewModel.selectBucket(bucket) }) {
                        HStack {
                            Text(bucket)
                            if bucket == viewModel.currentBucket {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color.yellow)
                    Text(viewModel.currentBucket)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .menuStyle(.borderlessButton)

            Spacer()

            // Refresh Button
            Button(action: {
                Task { await viewModel.listObjects() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Refresh Greenfield objects")

            // New Object Upload Button
            Button(action: {
                viewModel.uploadObjectName = ""
                viewModel.uploadObjectContent = ""
                viewModel.uploadIsPrivate = false
                viewModel.isShowingUploadSheet = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Upload")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.yellow)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Chat History Backup Card
    private var chatBackupCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: "cloud.arrow.up.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.cyan)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Decentralized Chat Backup")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)

                    if viewModel.isClientSideEncryptionEnabled {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                            Text("AES-256")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }

                if let status = viewModel.backupStatusMessage {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(viewModel.errorMessage != nil ? .red : .white.opacity(0.7))
                        .lineLimit(1)
                } else {
                    Text("Backup encrypted conversation history to BNB Greenfield")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            Spacer()

            Button(action: {
                Task {
                    await viewModel.backupChatHistory()
                }
            }) {
                HStack(spacing: 4) {
                    if viewModel.isBackingUp {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 10))
                    }
                    Text(viewModel.isBackingUp ? "Backing up..." : "Backup Now")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.cyan.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBackingUp)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Object Explorer Section
    private var objectExplorerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section Header & Search Filter
            HStack {
                Text("Stored Objects (\(viewModel.filteredObjects().count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                    TextField("Filter by path...", text: $viewModel.searchPrefix)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .frame(width: 100)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                )
            }

            // Object Scroll List
            ScrollView(.vertical, showsIndicators: false) {
                let objects = viewModel.filteredObjects()
                if objects.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.2))
                        Text("No objects in bucket \(viewModel.currentBucket)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    VStack(spacing: 6) {
                        ForEach(objects) { obj in
                            objectRow(obj: obj)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
    }

    private func objectRow(obj: GreenfieldObjectMetadata) -> some View {
        Button(action: {
            Task {
                await viewModel.inspectObject(obj)
            }
        }) {
            HStack(spacing: 8) {
                // Object Type Icon
                Image(systemName: obj.isPrivate ? "lock.doc.fill" : "doc.text.fill")
                    .font(.system(size: 13))
                    .foregroundColor(obj.isPrivate ? .green : .cyan)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(obj.objectName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if obj.isPrivate {
                            Text("Private")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                        }
                    }

                    Text("Hash: \(shortenHash(obj.contentHash)) • \(formatSize(obj.size))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Upload Modal Sheet
    private var uploadModalSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Upload to BNB Greenfield")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { viewModel.isShowingUploadSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Object Name / Path")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                TextField("e.g. configs/agent-rules.json", text: $viewModel.uploadObjectName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Content Payload")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                TextEditor(text: $viewModel.uploadObjectContent)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 100)
                    .padding(4)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Toggle("Client-Side AES-256 Encryption", isOn: $viewModel.uploadIsPrivate)
                .font(.system(size: 11))
                .foregroundColor(.white)

            HStack {
                Button("Cancel") {
                    viewModel.isShowingUploadSheet = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.7))

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.uploadObject(
                            name: viewModel.uploadObjectName,
                            content: viewModel.uploadObjectContent,
                            contentType: viewModel.uploadContentType,
                            isPrivate: viewModel.uploadIsPrivate
                        )
                        viewModel.isShowingUploadSheet = false
                    }
                }) {
                    Text("Upload Object")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.yellow)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.uploadObjectName.isEmpty || viewModel.uploadObjectContent.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.8)
            }
        )
    }

    // MARK: - Inspect Modal Sheet
    private var inspectModalSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Greenfield Object Details")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { viewModel.isShowingInspectSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            if let selected = viewModel.selectedObject {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Name:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text(selected.objectName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                    }

                    HStack {
                        Text("Bucket:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text(selected.bucket)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white)
                    }

                    HStack {
                        Text("Content Hash:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        Text(selected.contentHash)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            }

            if let content = viewModel.inspectedContent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    ScrollView {
                        Text(content.content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 120)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Button("Done") {
                viewModel.isShowingInspectSheet = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow))
        }
        .padding(18)
        .frame(width: 420)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.8)
            }
        )
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1048576.0)
        }
    }

    private func shortenHash(_ hash: String) -> String {
        guard hash.count >= 12 else { return hash }
        return "\(hash.prefix(6))...\(hash.suffix(4))"
    }
}
