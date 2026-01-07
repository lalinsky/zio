const std = @import("std");

// Type aliases
pub const DWORD = std.os.windows.DWORD;
pub const LPCWSTR = std.os.windows.LPCWSTR;
pub const BOOL = std.os.windows.BOOL;
pub const HANDLE = std.os.windows.HANDLE;
pub const LPVOID = std.os.windows.LPVOID;
pub const LARGE_INTEGER = std.os.windows.LARGE_INTEGER;
pub const OVERLAPPED = std.os.windows.OVERLAPPED;
pub const ULONG_PTR = std.os.windows.ULONG_PTR;
pub const PAPCFUNC = *const fn (ULONG_PTR) callconv(.winapi) void;

// MoveFileEx flags
pub const MOVEFILE_COPY_ALLOWED = 2;
pub const MOVEFILE_CREATE_HARDLINK = 16;
pub const MOVEFILE_DELAY_UNTIL_REBOOT = 4;
pub const MOVEFILE_FAIL_IF_NOT_TRACKABLE = 32;
pub const MOVEFILE_REPLACE_EXISTING = 1;
pub const MOVEFILE_WRITE_THROUGH = 8;

// File functions
pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: LPCWSTR,
    lpNewFileName: LPCWSTR,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn FlushFileBuffers(
    hFile: HANDLE,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileSizeEx(
    hFile: HANDLE,
    lpFileSize: *LARGE_INTEGER,
) callconv(.winapi) BOOL;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub extern "kernel32" fn GetFileInformationByHandle(
    hFile: HANDLE,
    lpFileInformation: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) BOOL;

/// Convert Windows FILETIME to nanoseconds since Unix epoch.
/// FILETIME is 100-nanosecond intervals since January 1, 1601.
/// Unix epoch is January 1, 1970.
pub fn fileTimeToNanos(ft: FILETIME) i64 {
    // 100-nanosecond intervals between 1601 and 1970
    const EPOCH_DIFF: i64 = 116444736000000000;
    const ticks: i64 = (@as(i64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return (ticks - EPOCH_DIFF) * 100;
}

// IOCP functions
pub extern "kernel32" fn GetQueuedCompletionStatusEx(
    CompletionPort: HANDLE,
    lpCompletionPortEntries: [*]std.os.windows.OVERLAPPED_ENTRY,
    ulCount: DWORD,
    ulNumEntriesRemoved: *DWORD,
    dwMilliseconds: DWORD,
    fAlertable: BOOL,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CancelIoEx(
    hFile: HANDLE,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: HANDLE,
    hSourceHandle: HANDLE,
    hTargetProcessHandle: HANDLE,
    lpTargetHandle: *HANDLE,
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwOptions: DWORD,
) callconv(.winapi) BOOL;

// Thread/APC functions
pub extern "kernel32" fn QueueUserAPC(
    pfnAPC: PAPCFUNC,
    hThread: HANDLE,
    dwData: ULONG_PTR,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn Sleep(
    dwMilliseconds: DWORD,
) callconv(.winapi) void;

pub extern "kernel32" fn SleepEx(
    dwMilliseconds: DWORD,
    bAlertable: BOOL,
) callconv(.winapi) DWORD;

// Error handling
pub extern "kernel32" fn GetLastError() callconv(.winapi) std.os.windows.Win32Error;

/// Custom WinsockError enum for compatibility between Zig 0.15 and 0.16.
/// Zig 0.15 uses WSAE* prefix, Zig 0.16 uses E* prefix.
/// We define our own with consistent naming (using 0.16 style).
pub const WinsockError = enum(u16) {
    /// No error
    SUCCESS = 0,
    /// Specified event object handle is invalid.
    INVALID_HANDLE = 6,
    /// Insufficient memory available.
    NOT_ENOUGH_MEMORY = 8,
    /// One or more parameters are invalid.
    INVALID_PARAMETER = 87,
    /// Overlapped operation aborted.
    OPERATION_ABORTED = 995,
    /// Overlapped I/O event object not in signaled state.
    IO_INCOMPLETE = 996,
    /// The application has initiated an overlapped operation that cannot be completed immediately.
    IO_PENDING = 997,
    /// Interrupted function call.
    EINTR = 10004,
    /// File handle is not valid.
    EBADF = 10009,
    /// Permission denied.
    EACCES = 10013,
    /// Bad address.
    EFAULT = 10014,
    /// Invalid argument.
    EINVAL = 10022,
    /// Too many open files.
    EMFILE = 10024,
    /// Resource temporarily unavailable.
    EWOULDBLOCK = 10035,
    /// Operation now in progress.
    EINPROGRESS = 10036,
    /// Operation already in progress.
    EALREADY = 10037,
    /// Socket operation on nonsocket.
    ENOTSOCK = 10038,
    /// Destination address required.
    EDESTADDRREQ = 10039,
    /// Message too long.
    EMSGSIZE = 10040,
    /// Protocol wrong type for socket.
    EPROTOTYPE = 10041,
    /// Bad protocol option.
    ENOPROTOOPT = 10042,
    /// Protocol not supported.
    EPROTONOSUPPORT = 10043,
    /// Socket type not supported.
    ESOCKTNOSUPPORT = 10044,
    /// Operation not supported.
    EOPNOTSUPP = 10045,
    /// Protocol family not supported.
    EPFNOSUPPORT = 10046,
    /// Address family not supported by protocol family.
    EAFNOSUPPORT = 10047,
    /// Address already in use.
    EADDRINUSE = 10048,
    /// Cannot assign requested address.
    EADDRNOTAVAIL = 10049,
    /// Network is down.
    ENETDOWN = 10050,
    /// Network is unreachable.
    ENETUNREACH = 10051,
    /// Network dropped connection on reset.
    ENETRESET = 10052,
    /// Software caused connection abort.
    ECONNABORTED = 10053,
    /// Connection reset by peer.
    ECONNRESET = 10054,
    /// No buffer space available.
    ENOBUFS = 10055,
    /// Socket is already connected.
    EISCONN = 10056,
    /// Socket is not connected.
    ENOTCONN = 10057,
    /// Cannot send after socket shutdown.
    ESHUTDOWN = 10058,
    /// Connection timed out.
    ETIMEDOUT = 10060,
    /// Connection refused.
    ECONNREFUSED = 10061,
    /// No route to host.
    EHOSTUNREACH = 10065,
    /// Network subsystem is unavailable.
    SYSNOTREADY = 10091,
    /// Winsock.dll version out of range.
    VERNOTSUPPORTED = 10092,
    /// Successful WSAStartup not yet performed.
    NOTINITIALISED = 10093,
    /// Graceful shutdown in progress.
    EDISCON = 10101,
    /// Class type not found.
    TYPE_NOT_FOUND = 10109,
    /// Host not found (DNS).
    HOST_NOT_FOUND = 11001,
    /// Nonauthoritative host not found (DNS).
    TRY_AGAIN = 11002,
    /// This is a nonrecoverable error (DNS).
    NO_RECOVERY = 11003,
    /// Valid name, no data record of requested type (DNS).
    NO_DATA = 11004,
    _,
};

/// Get the last Winsock error as our custom WinsockError type.
pub fn WSAGetLastError() WinsockError {
    return @enumFromInt(@intFromEnum(std.os.windows.ws2_32.WSAGetLastError()));
}
