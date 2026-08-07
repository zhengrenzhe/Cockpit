import Darwin

public enum UnixDomainSocketError: Error, Hashable, Sendable {
    case invalidNamespace
    case pathTooLong
    case unsafeDirectory
    case unsafeSocket
    case serverAlreadyRunning
    case staleSocketRace
    case permissionMismatch
    case systemCall(function: String, errno: Int32)
}

public protocol PeerCredentialReading: Sendable {
    func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t)
}

public struct DarwinPeerCredentialReader: PeerCredentialReading {
    public init() {}

    public func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            throw UnixDomainSocketError.systemCall(function: "getpeereid", errno: errno)
        }
        return (uid, gid)
    }
}

public struct UnixSocketPathStatus: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case directory
        case socket
        case symbolicLink
        case other
    }

    public let kind: Kind
    public let owner: uid_t
    public let permissions: mode_t
    public let device: dev_t
    public let inode: ino_t
}

public struct UnixDomainSocketAddress: @unchecked Sendable {
    public let value: sockaddr_un
    public let length: socklen_t

    public init(path: String) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.contains(0), pathBytes.count + 1 <= capacity else {
            throw UnixDomainSocketError.pathTooLong
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }

        let addressLength = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + pathBytes.count + 1
        address.sun_len = UInt8(addressLength)
        value = address
        length = socklen_t(addressLength)
    }
}

public protocol UnixDomainSocketSystemCalls: Sendable {
    func effectiveUserID() -> uid_t
    func createStreamSocket() throws -> Int32
    func setCloseOnExec(_ descriptor: Int32) throws
    func setNoSigPipe(_ descriptor: Int32) throws
    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws
    func listen(_ descriptor: Int32, backlog: Int32) throws
    func accept(_ descriptor: Int32) throws -> Int32
    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws
    func pathStatus(_ path: String) throws -> UnixSocketPathStatus?
    func makeDirectory(_ path: String, permissions: mode_t) throws
    func setPermissions(_ path: String, permissions: mode_t) throws
    func unlink(_ path: String) throws
    func close(_ descriptor: Int32)
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int
}

public struct DarwinUnixDomainSocketSystemCalls: UnixDomainSocketSystemCalls {
    public init() {}

    public func effectiveUserID() -> uid_t { geteuid() }
    public func createStreamSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemCall("socket") }
        return descriptor
    }

    public func setCloseOnExec(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw systemCall("fcntl")
        }
    }

    public func setNoSigPipe(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw systemCall("fcntl")
        }
    }

    public func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        var value = address.value
        let result = withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, address.length)
            }
        }
        guard result == 0 else { throw systemCall("bind") }
    }

    public func listen(_ descriptor: Int32, backlog: Int32) throws {
        guard Darwin.listen(descriptor, backlog) == 0 else { throw systemCall("listen") }
    }

    public func accept(_ descriptor: Int32) throws -> Int32 {
        let acceptedDescriptor = Darwin.accept(descriptor, nil, nil)
        guard acceptedDescriptor >= 0 else { throw systemCall("accept") }
        return acceptedDescriptor
    }

    public func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        var value = address.value
        let result = withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.length)
            }
        }
        guard result == 0 else { throw systemCall("connect") }
    }

    public func pathStatus(_ path: String) throws -> UnixSocketPathStatus? {
        var pathStat = stat()
        let lstatResult = path.withCString { Darwin.lstat($0, &pathStat) }
        if lstatResult != 0 {
            if errno == ENOENT { return nil }
            throw systemCall("lstat")
        }

        let initialKind = kind(for: pathStat.st_mode)
        if initialKind == .directory {
            let descriptor = path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw systemCall("open") }
            defer { Darwin.close(descriptor) }

            var descriptorStat = stat()
            guard Darwin.fstat(descriptor, &descriptorStat) == 0 else {
                throw systemCall("fstat")
            }
            guard kind(for: descriptorStat.st_mode) == .directory,
                  descriptorStat.st_dev == pathStat.st_dev,
                  descriptorStat.st_ino == pathStat.st_ino else {
                throw UnixDomainSocketError.unsafeDirectory
            }
            pathStat = descriptorStat
        }

        return status(from: pathStat)
    }

    public func makeDirectory(_ path: String, permissions: mode_t) throws {
        let result = path.withCString { Darwin.mkdir($0, permissions) }
        guard result == 0 else { throw systemCall("mkdir") }
    }

    public func setPermissions(_ path: String, permissions: mode_t) throws {
        let result = path.withCString { Darwin.chmod($0, permissions) }
        guard result == 0 else { throw systemCall("chmod") }
    }

    public func unlink(_ path: String) throws {
        let result = path.withCString { Darwin.unlink($0) }
        guard result == 0 else { throw systemCall("unlink") }
    }

    public func close(_ descriptor: Int32) { Darwin.close(descriptor) }

    public func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        guard count >= 0 else { throw systemCall("read") }
        return count
    }

    public func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int {
        let count = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        guard count >= 0 else { throw systemCall("write") }
        return count
    }

    private func status(from value: stat) -> UnixSocketPathStatus {
        UnixSocketPathStatus(
            kind: kind(for: value.st_mode),
            owner: value.st_uid,
            permissions: value.st_mode & mode_t(0o7777),
            device: value.st_dev,
            inode: value.st_ino
        )
    }

    private func kind(for mode: mode_t) -> UnixSocketPathStatus.Kind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFSOCK): .socket
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
    }

    private func systemCall(_ function: String) -> UnixDomainSocketError {
        .systemCall(function: function, errno: errno)
    }
}
