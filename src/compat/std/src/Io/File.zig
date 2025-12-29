const File = @This();

const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;

const std = @import("std");
const Io = @import("../Io.zig");
const assert = std.debug.assert;
const Dir = @import("Dir.zig");

handle: Handle,

pub const Reader = @import("File/Reader.zig");
pub const Writer = @import("File/Writer.zig");
pub const Atomic = @import("File/Atomic.zig");

pub const Handle = std.posix.fd_t;
pub const INode = std.posix.ino_t;
pub const NLink = std.posix.nlink_t;
pub const Uid = std.posix.uid_t;
pub const Gid = std.posix.gid_t;

pub const Kind = enum {
    block_device,
    character_device,
    directory,
    named_pipe,
    sym_link,
    file,
    unix_domain_socket,
    whiteout,
    door,
    event_port,
    unknown,
};

pub const Stat = struct {
    /// A number that the system uses to point to the file metadata. This
    /// number is not guaranteed to be unique across time, as some file
    /// systems may reuse an inode after its file has been deleted. Some
    /// systems may change the inode of a file over time.
    ///
    /// On Linux, the inode is a structure that stores the metadata, and
    /// the inode _number_ is what you see here: the index number of the
    /// inode.
    ///
    /// The FileIndex on Windows is similar. It is a number for a file that
    /// is unique to each filesystem.
    inode: INode,
    nlink: NLink,
    size: u64,
    permissions: Permissions,
    kind: Kind,
    /// Last access time in nanoseconds, relative to UTC 1970-01-01.
    ///
    /// Filesystems generally find this value problematic to keep updated since
    /// it turns read-only file system accesses into file system mutations.
    /// Some systems report stale values, and some systems explicitly refuse to
    /// report this value. The latter case is handled by `null`.
    atime: ?Io.Timestamp,
    /// Last modification time in nanoseconds, relative to UTC 1970-01-01.
    mtime: Io.Timestamp,
    /// Last status/metadata change time in nanoseconds, relative to UTC 1970-01-01.
    ctime: Io.Timestamp,
};

pub fn stdout() File {
    return .{ .handle = if (is_windows) std.os.windows.peb().ProcessParameters.hStdOutput else std.posix.STDOUT_FILENO };
}

pub fn stderr() File {
    return .{ .handle = if (is_windows) std.os.windows.peb().ProcessParameters.hStdError else std.posix.STDERR_FILENO };
}

pub fn stdin() File {
    return .{ .handle = if (is_windows) std.os.windows.peb().ProcessParameters.hStdInput else std.posix.STDIN_FILENO };
}

pub const StatError = error{
    SystemResources,
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to get its filestat information.
    AccessDenied,
    PermissionDenied,
    /// Attempted to stat a non-file stream.
    Streaming,
} || Io.Cancelable || Io.UnexpectedError;

/// Returns `Stat` containing basic information about the `File`.
pub fn stat(file: File, io: Io) StatError!Stat {
    return io.vtable.fileStat(io.userdata, file);
}

pub const OpenMode = enum {
    read_only,
    write_only,
    read_write,
};

pub const Lock = enum {
    none,
    shared,
    exclusive,
};

pub const OpenFlags = struct {
    mode: OpenMode = .read_only,

    /// Determines the behavior when opening a path that refers to a directory.
    ///
    /// If set to true, directories may be opened, but `error.IsDir` is still
    /// possible in certain scenarios, e.g. attempting to open a directory with
    /// write permissions.
    ///
    /// If set to false, `error.IsDir` will always be returned when opening a directory.
    ///
    /// When set to false:
    /// * On Windows, the behavior is implemented without any extra syscalls.
    /// * On other operating systems, the behavior is implemented with an additional
    ///   `fstat` syscall.
    allow_directory: bool = true,
    /// Indicates intent for only some operations to be performed on this
    /// opened file:
    /// * `close`
    /// * `stat`
    /// On Linux and FreeBSD, this corresponds to `std.posix.O.PATH`.
    path_only: bool = false,

    /// Open the file with an advisory lock to coordinate with other processes
    /// accessing it at the same time. An exclusive lock will prevent other
    /// processes from acquiring a lock. A shared lock will prevent other
    /// processes from acquiring a exclusive lock, but does not prevent
    /// other process from getting their own shared locks.
    ///
    /// The lock is advisory, except on Linux in very specific circumstances[1].
    /// This means that a process that does not respect the locking API can still get access
    /// to the file, despite the lock.
    ///
    /// On these operating systems, the lock is acquired atomically with
    /// opening the file:
    /// * Darwin
    /// * DragonFlyBSD
    /// * FreeBSD
    /// * Haiku
    /// * NetBSD
    /// * OpenBSD
    /// On these operating systems, the lock is acquired via a separate syscall
    /// after opening the file:
    /// * Linux
    /// * Windows
    ///
    /// [1]: https://www.kernel.org/doc/Documentation/filesystems/mandatory-locking.txt
    lock: Lock = .none,

    /// Sets whether or not to wait until the file is locked to return. If set to true,
    /// `error.WouldBlock` will be returned. Otherwise, the file will wait until the file
    /// is available to proceed.
    lock_nonblocking: bool = false,

    /// Set this to allow the opened file to automatically become the
    /// controlling TTY for the current process.
    allow_ctty: bool = false,

    follow_symlinks: bool = true,

    pub fn isRead(self: OpenFlags) bool {
        return self.mode != .write_only;
    }

    pub fn isWrite(self: OpenFlags) bool {
        return self.mode != .read_only;
    }
};

pub const CreateFlags = struct {
    /// Whether the file will be created with read access.
    read: bool = false,

    /// If the file already exists, and is a regular file, and the access
    /// mode allows writing, it will be truncated to length 0.
    truncate: bool = true,

    /// Ensures that this open call creates the file, otherwise causes
    /// `error.PathAlreadyExists` to be returned.
    exclusive: bool = false,

    /// Open the file with an advisory lock to coordinate with other processes
    /// accessing it at the same time. An exclusive lock will prevent other
    /// processes from acquiring a lock. A shared lock will prevent other
    /// processes from acquiring a exclusive lock, but does not prevent
    /// other process from getting their own shared locks.
    ///
    /// The lock is advisory, except on Linux in very specific circumstances[1].
    /// This means that a process that does not respect the locking API can still get access
    /// to the file, despite the lock.
    ///
    /// On these operating systems, the lock is acquired atomically with
    /// opening the file:
    /// * Darwin
    /// * DragonFlyBSD
    /// * FreeBSD
    /// * Haiku
    /// * NetBSD
    /// * OpenBSD
    /// On these operating systems, the lock is acquired via a separate syscall
    /// after opening the file:
    /// * Linux
    /// * Windows
    ///
    /// [1]: https://www.kernel.org/doc/Documentation/filesystems/mandatory-locking.txt
    lock: Lock = .none,

    /// Sets whether or not to wait until the file is locked to return. If set to true,
    /// `error.WouldBlock` will be returned. Otherwise, the file will wait until the file
    /// is available to proceed.
    lock_nonblocking: bool = false,

    permissions: Permissions = .default_file,
};

pub const OpenError = error{
    SharingViolation,
    PipeBusy,
    NoDevice,
    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,
    /// On Windows, antivirus software is enabled by default. It can be
    /// disabled, but Windows Update sometimes ignores the user's preference
    /// and re-enables it. When enabled, antivirus software on Windows
    /// intercepts file system operations and makes them significantly slower
    /// in addition to possibly failing with this error code.
    AntivirusInterference,
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to open a new resource relative to it.
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    /// Either:
    /// * One of the path components does not exist.
    /// * Cwd was used, but cwd has been deleted.
    /// * The path associated with the open directory handle has been deleted.
    /// * On macOS, multiple processes or threads raced to create the same file
    ///   with `O.EXCL` set to `false`.
    FileNotFound,
    /// The path exceeded `max_path_bytes` bytes.
    /// Insufficient kernel memory was available, or
    /// the named file is a FIFO and per-user hard limit on
    /// memory allocation for pipes has been reached.
    SystemResources,
    /// The file is too large to be opened. This error is unreachable
    /// for 64-bit targets, as well as when opening directories.
    FileTooBig,
    /// Either:
    /// * The path refers to a directory and write permissions were requested.
    /// * The path refers to a directory and `allow_directory` was set to false.
    IsDir,
    /// A new path cannot be created because the device has no room for the new file.
    /// This error is only reachable when the `CREAT` flag is provided.
    NoSpaceLeft,
    /// A component used as a directory in the path was not, in fact, a directory, or
    /// `DIRECTORY` was specified and the path was not a directory.
    NotDir,
    /// The path already exists and the `CREAT` and `EXCL` flags were provided.
    PathAlreadyExists,
    DeviceBusy,
    FileLocksUnsupported,
    /// One of these three things:
    /// * pathname  refers to an executable image which is currently being
    ///   executed and write access was requested.
    /// * pathname refers to a file that is currently in  use  as  a  swap
    ///   file, and the O_TRUNC flag was specified.
    /// * pathname  refers  to  a file that is currently being read by the
    ///   kernel (e.g., for module/firmware loading), and write access was
    ///   requested.
    FileBusy,
    /// Non-blocking was requested and the operation cannot return immediately.
    WouldBlock,
} || Io.Dir.PathNameError || Io.Cancelable || Io.UnexpectedError;

pub fn close(file: File, io: Io) void {
    return io.vtable.fileClose(io.userdata, (&file)[0..1]);
}

pub fn closeMany(io: Io, files: []const File) void {
    return io.vtable.fileClose(io.userdata, files);
}

pub const SyncError = error{
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    AccessDenied,
} || Io.Cancelable || Io.UnexpectedError;

/// Blocks until all pending file contents and metadata modifications for the
/// file have been synchronized with the underlying filesystem.
///
/// This does not ensure that metadata for the directory containing the file
/// has also reached disk.
pub fn sync(file: File, io: Io) SyncError!void {
    return io.vtable.fileSync(io.userdata, file);
}

/// Test whether the file refers to a terminal (similar to libc "isatty").
///
/// See also:
/// * `enableAnsiEscapeCodes`
/// * `supportsAnsiEscapeCodes`.
pub fn isTty(file: File, io: Io) Io.Cancelable!bool {
    return io.vtable.fileIsTty(io.userdata, file);
}

pub const EnableAnsiEscapeCodesError = error{
    NotTerminalDevice,
} || Io.Cancelable || Io.UnexpectedError;

pub fn enableAnsiEscapeCodes(file: File, io: Io) EnableAnsiEscapeCodesError!void {
    return io.vtable.fileEnableAnsiEscapeCodes(io.userdata, file);
}

/// Test whether ANSI escape codes will be treated as such without
/// attempting to enable support for ANSI escape codes.
pub fn supportsAnsiEscapeCodes(file: File, io: Io) Io.Cancelable!bool {
    return io.vtable.fileSupportsAnsiEscapeCodes(io.userdata, file);
}

pub const SetLengthError = error{
    FileTooBig,
    InputOutput,
    FileBusy,
    AccessDenied,
    PermissionDenied,
    NonResizable,
} || Io.Cancelable || Io.UnexpectedError;

/// Truncates or expands the file, populating any new data with zeroes.
///
/// The file offset after this call is left unchanged.
pub fn setLength(file: File, io: Io, new_length: u64) SetLengthError!void {
    return io.vtable.fileSetLength(io.userdata, file, new_length);
}

pub const LengthError = StatError;

/// Retrieve the ending byte index of the file.
///
/// Sometimes cheaper than `stat` if only the length is needed.
pub fn length(file: File, io: Io) LengthError!u64 {
    return io.vtable.fileLength(io.userdata, file);
}

pub const SetPermissionsError = error{
    AccessDenied,
    PermissionDenied,
    InputOutput,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    ReadOnlyFileSystem,
} || Io.Cancelable || Io.UnexpectedError;

/// Also known as "chmod".
///
/// The process must have the correct privileges in order to do this
/// successfully, or must have the effective user ID matching the owner of the
/// file.
pub fn setPermissions(file: File, io: Io, new_permissions: Permissions) SetPermissionsError!void {
    return io.vtable.fileSetPermissions(io.userdata, file, new_permissions);
}

pub const SetOwnerError = error{
    AccessDenied,
    PermissionDenied,
    InputOutput,
    SymLinkLoop,
    FileNotFound,
    SystemResources,
    ReadOnlyFileSystem,
} || Io.Cancelable || Io.UnexpectedError;

/// Also known as "chown".
///
/// The process must have the correct privileges in order to do this
/// successfully. The group may be changed by the owner of the file to any
/// group of which the owner is a member. If the owner or group is specified as
/// `null`, the ID is not changed.
pub fn setOwner(file: File, io: Io, owner: ?Uid, group: ?Gid) SetOwnerError!void {
    return io.vtable.fileSetOwner(io.userdata, file, owner, group);
}

/// Cross-platform representation of permissions on a file.
///
/// On POSIX systems this corresponds to "mode" and on Windows this corresponds to "attributes".
pub const Permissions = std.Options.FilePermissions orelse if (is_windows) enum(std.os.windows.DWORD) {
    default_file = 0,
    _,

    pub const default_dir: @This() = .default_file;
    pub const executable_file: @This() = .default_file;
    pub const has_executable_bit = false;

    const windows = std.os.windows;

    pub fn toAttributes(self: @This()) windows.FILE.ATTRIBUTE {
        return @bitCast(@intFromEnum(self));
    }

    pub fn readOnly(self: @This()) bool {
        const attributes = toAttributes(self);
        return attributes & windows.FILE_ATTRIBUTE_READONLY != 0;
    }

    pub fn setReadOnly(self: @This(), read_only: bool) @This() {
        const attributes = toAttributes(self);
        return @enumFromInt(if (read_only)
            attributes | windows.FILE_ATTRIBUTE_READONLY
        else
            attributes & ~@as(windows.DWORD, windows.FILE_ATTRIBUTE_READONLY));
    }
} else if (std.posix.mode_t != u0) enum(std.posix.mode_t) {
    /// This is the default mode given to POSIX operating systems for creating
    /// files. `0o666` is "-rw-rw-rw-" which is counter-intuitive at first,
    /// since most people would expect "-rw-r--r--", for example, when using
    /// the `touch` command, which would correspond to `0o644`. However, POSIX
    /// libc implementations use `0o666` inside `fopen` and then rely on the
    /// process-scoped "umask" setting to adjust this number for file creation.
    default_file = 0o666,
    default_dir = 0o755,
    executable_file = 0o777,
    _,

    pub const has_executable_bit = native_os != .wasi;

    pub fn toMode(self: @This()) std.posix.mode_t {
        return @intFromEnum(self);
    }

    pub fn fromMode(mode: std.posix.mode_t) @This() {
        return @enumFromInt(mode);
    }

    /// Returns `true` if and only if no class has write permissions.
    pub fn readOnly(self: @This()) bool {
        const mode = toMode(self);
        return mode & 0o222 == 0;
    }

    /// Enables write permission for all classes.
    pub fn setReadOnly(self: @This(), read_only: bool) @This() {
        const mode = toMode(self);
        const o222 = @as(std.posix.mode_t, 0o222);
        return @enumFromInt(if (read_only) mode & ~o222 else mode | o222);
    }
} else enum(u0) {
    default_file = 0,
    pub const default_dir: @This() = .default_file;
    pub const executable_file: @This() = .default_file;
    pub const has_executable_bit = false;
};

pub const SetTimestampsError = error{
    /// times is NULL, or both nsec values are UTIME_NOW, and either:
    /// *  the effective user ID of the caller does not match the  owner
    ///    of  the  file,  the  caller does not have write access to the
    ///    file, and the caller is not privileged (Linux: does not  have
    ///    either  the  CAP_FOWNER  or the CAP_DAC_OVERRIDE capability);
    ///    or,
    /// *  the file is marked immutable (see chattr(1)).
    AccessDenied,
    /// The caller attempted to change one or both timestamps to a value
    /// other than the current time, or to change one of the  timestamps
    /// to the current time while leaving the other timestamp unchanged,
    /// (i.e., times is not NULL, neither nsec  field  is  UTIME_NOW,
    /// and neither nsec field is UTIME_OMIT) and either:
    /// *  the  caller's  effective  user ID does not match the owner of
    ///    file, and the caller is not privileged (Linux: does not  have
    ///    the CAP_FOWNER capability); or,
    /// *  the file is marked append-only or immutable (see chattr(1)).
    PermissionDenied,
    ReadOnlyFileSystem,
} || Io.Cancelable || Io.UnexpectedError;

pub const SetTimestampsOptions = struct {
    access_timestamp: SetTimestamp = .unchanged,
    modify_timestamp: SetTimestamp = .unchanged,
};

pub const SetTimestamp = union(enum) {
    /// Leave the existing timestamp unmodified.
    unchanged,
    /// Set to current time using `Io.Clock.real`.
    now,
    /// Set to provided timestamp using `Io.Clock.real`.
    new: Io.Timestamp,

    /// Convenience for interacting with `Stat`, in which `null` indicates `unchanged`.
    pub fn init(optional: ?Io.Timestamp) SetTimestamp {
        return if (optional) |t| .{ .new = t } else .unchanged;
    }
};

/// The granularity that ultimately is stored depends on the combination of
/// operating system and file system. When a value as provided that exceeds
/// this range, the value is clamped to the maximum.
pub fn setTimestamps(file: File, io: Io, options: SetTimestampsOptions) SetTimestampsError!void {
    return io.vtable.fileSetTimestamps(io.userdata, file, options);
}

/// Sets the accessed and modification timestamps of `file` to the current wall
/// clock time.
///
/// The granularity that ultimately is stored depends on the combination of
/// operating system and file system.
pub fn setTimestampsNow(file: File, io: Io) SetTimestampsError!void {
    return io.vtable.fileSetTimestamps(io.userdata, file, .{
        .access_timestamp = .now,
        .modify_timestamp = .now,
    });
}

/// Returns 0 on stream end or if `buffer` has no space available for data.
///
/// See also:
/// * `reader`
pub fn readStreaming(file: File, io: Io, buffer: []const []u8) Reader.Error!usize {
    return io.vtable.fileReadStreaming(io.userdata, file, buffer);
}

pub const ReadPositionalError = Reader.Error || error{Unseekable};

/// Returns 0 on stream end or if `buffer` has no space available for data.
///
/// See also:
/// * `reader`
pub fn readPositional(file: File, io: Io, buffer: []const []u8, offset: u64) ReadPositionalError!usize {
    return io.vtable.fileReadPositional(io.userdata, file, buffer, offset);
}

pub const WritePositionalError = Writer.Error || error{Unseekable};

/// See also:
/// * `writer`
pub fn writePositional(file: File, io: Io, buffer: []const []const u8, offset: u64) WritePositionalError!usize {
    return io.vtable.fileWritePositional(io.userdata, file, &.{}, buffer, 1, offset);
}

/// Equivalent to creating a positional writer, writing `bytes`, and then flushing.
pub fn writePositionalAll(file: File, io: Io, bytes: []const u8, offset: u64) WritePositionalError!void {
    var index: usize = 0;
    while (index < bytes.len)
        index += try io.vtable.fileWritePositional(io.userdata, file, &.{}, &.{bytes[index..]}, 1, offset + index);
}

pub const SeekError = error{
    Unseekable,
    /// The file descriptor does not hold the required rights to seek on it.
    AccessDenied,
} || Io.Cancelable || Io.UnexpectedError;

pub const WriteFilePositionalError = Writer.WriteFileError || error{Unseekable};

/// Defaults to positional reading; falls back to streaming.
///
/// Positional is more threadsafe, since the global seek position is not
/// affected.
///
/// See also:
/// * `readerStreaming`
pub fn reader(file: File, io: Io, buffer: []u8) Reader {
    return .init(file, io, buffer);
}

/// Equivalent to creating a positional reader and reading multiple times to fill `buffer`.
///
/// Returns number of bytes read into `buffer`. If less than `buffer.len`, end of file occurred.
///
/// See also:
/// * `reader`
pub fn readPositionalAll(file: File, io: Io, buffer: []u8, offset: u64) ReadPositionalError!usize {
    var index: usize = 0;
    while (index != buffer.len) {
        const amt = try file.readPositional(io, &.{buffer[index..]}, offset + index);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

/// Positional is more threadsafe, since the global seek position is not
/// affected, but when such syscalls are not available, preemptively
/// initializing in streaming mode skips a failed syscall.
///
/// See also:
/// * `reader`
pub fn readerStreaming(file: File, io: Io, buffer: []u8) Reader {
    return .initStreaming(file, io, buffer);
}

/// Defaults to positional reading; falls back to streaming.
///
/// Positional is more threadsafe, since the global seek position is not
/// affected.
pub fn writer(file: File, io: Io, buffer: []u8) Writer {
    return .init(file, io, buffer);
}

/// Positional is more threadsafe, since the global seek position is not
/// affected, but when such syscalls are not available, preemptively
/// initializing in streaming mode will skip a failed syscall.
pub fn writerStreaming(file: File, io: Io, buffer: []u8) Writer {
    return .initStreaming(file, io, buffer);
}

/// Equivalent to creating a streaming writer, writing `bytes`, and then flushing.
pub fn writeStreamingAll(file: File, io: Io, bytes: []const u8) Writer.Error!void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try io.vtable.fileWriteStreaming(io.userdata, file, &.{}, &.{bytes[index..]}, 1);
    }
}

pub const LockError = error{
    SystemResources,
    FileLocksUnsupported,
} || Io.Cancelable || Io.UnexpectedError;

/// Blocks when an incompatible lock is held by another process. A process may
/// hold only one type of lock (shared or exclusive) on a file. When a process
/// terminates in any way, the lock is released.
///
/// Assumes the file is unlocked.
pub fn lock(file: File, io: Io, l: Lock) LockError!void {
    return io.vtable.fileLock(io.userdata, file, l);
}

/// Assumes the file is locked.
pub fn unlock(file: File, io: Io) void {
    return io.vtable.fileUnlock(io.userdata, file);
}

/// Attempts to obtain a lock, returning `true` if the lock is obtained, and
/// `false` if there was an existing incompatible lock held. A process may hold
/// only one type of lock (shared or exclusive) on a file. When a process
/// terminates in any way, the lock is released.
///
/// Assumes the file is unlocked.
pub fn tryLock(file: File, io: Io, l: Lock) LockError!bool {
    return io.vtable.fileTryLock(io.userdata, file, l);
}

pub const DowngradeLockError = Io.Cancelable || Io.UnexpectedError;

/// Assumes the file is already locked in exclusive mode.
/// Atomically modifies the lock to be in shared mode, without releasing it.
pub fn downgradeLock(file: File, io: Io) LockError!void {
    return io.vtable.fileDowngradeLock(io.userdata, file);
}

pub const RealPathError = error{
    /// This operating system, file system, or `Io` implementation does not
    /// support realpath operations.
    OperationUnsupported,
    /// The full file system path could not fit into the provided buffer, or
    /// due to its length could not be obtained via realpath functions no
    /// matter the buffer size provided.
    NameTooLong,
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    NotDir,
    SymLinkLoop,
    InputOutput,
    FileTooBig,
    IsDir,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
    NoSpaceLeft,
    FileSystem,
    DeviceBusy,
    SharingViolation,
    PipeBusy,
    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,
    PathAlreadyExists,
    /// On Windows, antivirus software is enabled by default. It can be
    /// disabled, but Windows Update sometimes ignores the user's preference
    /// and re-enables it. When enabled, antivirus software on Windows
    /// intercepts file system operations and makes them significantly slower
    /// in addition to possibly failing with this error code.
    AntivirusInterference,
    /// On Windows, the volume does not contain a recognized file system. File
    /// system drivers might not be loaded, or the volume may be corrupt.
    UnrecognizedVolume,
} || Io.Cancelable || Io.UnexpectedError;

/// Obtains the canonicalized absolute path name corresponding to an open file
/// handle.
///
/// This function has limited platform support, and using it can lead to
/// unnecessary failures and race conditions. It is generally advisable to
/// avoid this function entirely.
pub fn realPath(file: File, io: Io, out_buffer: []u8) RealPathError!usize {
    return io.vtable.fileRealPath(io.userdata, file, out_buffer);
}

test {
    _ = Reader;
    _ = Writer;
    _ = Atomic;
}
