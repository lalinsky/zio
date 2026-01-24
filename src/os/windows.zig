const std = @import("std");

// Type aliases
pub const DWORD = std.os.windows.DWORD;
pub const LPCWSTR = std.os.windows.LPCWSTR;
pub const BOOL = std.os.windows.BOOL;
pub const HANDLE = std.os.windows.HANDLE;
pub const LPVOID = std.os.windows.LPVOID;
pub const LARGE_INTEGER = std.os.windows.LARGE_INTEGER;
pub const OVERLAPPED = std.os.windows.OVERLAPPED;
pub const OVERLAPPED_ENTRY = std.os.windows.OVERLAPPED_ENTRY;
pub const ULONG = std.os.windows.ULONG;
pub const ULONG_PTR = std.os.windows.ULONG_PTR;
pub const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
pub const PVOID = std.os.windows.PVOID;
pub const SIZE_T = std.os.windows.SIZE_T;
pub const NTSTATUS = std.os.windows.NTSTATUS;
pub const BOOLEAN = std.os.windows.BOOLEAN;
pub const IO_STATUS_BLOCK = std.os.windows.IO_STATUS_BLOCK;
pub const FILE_BOTH_DIR_INFORMATION = std.os.windows.FILE_BOTH_DIR_INFORMATION;
pub const FILE_INFORMATION_CLASS = std.os.windows.FILE_INFORMATION_CLASS;
pub const WCHAR = std.os.windows.WCHAR;
pub const PAPCFUNC = *const fn (ULONG_PTR) callconv(.winapi) void;
pub const HANDLER_ROUTINE = *const fn (dwCtrlType: DWORD) callconv(.winapi) BOOL;

// Constants
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const NAME_MAX = std.os.windows.NAME_MAX;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

/// Sentinel value representing the current working directory.
/// Similar to POSIX AT_FDCWD. This is not a real handle - it must be
/// detected and handled specially in path resolution functions.
pub const FDCWD: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -100))));

// DuplicateHandle options
pub const DUPLICATE_SAME_ACCESS: DWORD = 2;

// Console control events
pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_CLOSE_EVENT: DWORD = 2;

// Generic access rights
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const GENERIC_EXECUTE: DWORD = 0x20000000;
pub const GENERIC_ALL: DWORD = 0x10000000;

// File share modes
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;

// Creation disposition
pub const CREATE_NEW: DWORD = 1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;

// File attributes
pub const FILE_ATTRIBUTE_READONLY: DWORD = 0x1;
pub const FILE_ATTRIBUTE_HIDDEN: DWORD = 0x2;
pub const FILE_ATTRIBUTE_SYSTEM: DWORD = 0x4;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub const FILE_ATTRIBUTE_ARCHIVE: DWORD = 0x20;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x400;

// File flags
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;

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

pub extern "kernel32" fn CreateDirectoryW(
    lpPathName: LPCWSTR,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn RemoveDirectoryW(
    lpPathName: LPCWSTR,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
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

pub extern "kernel32" fn GetFileInformationByHandle(
    hFile: HANDLE,
    lpFileInformation: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: LPCWSTR,
) callconv(.winapi) DWORD;

pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;

pub extern "kernel32" fn SetFilePointerEx(
    hFile: HANDLE,
    liDistanceToMove: LARGE_INTEGER,
    lpNewFilePointer: ?*LARGE_INTEGER,
    dwMoveMethod: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetEndOfFile(
    hFile: HANDLE,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetFileTime(
    hFile: HANDLE,
    lpCreationTime: ?*const FILETIME,
    lpLastAccessTime: ?*const FILETIME,
    lpLastWriteTime: ?*const FILETIME,
) callconv(.winapi) BOOL;

pub const FILE_BEGIN: DWORD = 0;
pub const FILE_CURRENT: DWORD = 1;
pub const FILE_END: DWORD = 2;

// File time structures
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

/// 100-nanosecond intervals between 1601 and 1970
const EPOCH_DIFF: i64 = 116444736000000000;

/// Convert Windows FILETIME to nanoseconds since Unix epoch.
/// FILETIME is 100-nanosecond intervals since January 1, 1601.
/// Unix epoch is January 1, 1970.
pub fn fileTimeToNanos(ft: FILETIME) i64 {
    const ticks: i64 = (@as(i64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return (ticks - EPOCH_DIFF) * 100;
}

/// Convert nanoseconds since Unix epoch to Windows FILETIME.
pub fn nanosToFileTime(nanos: i96) FILETIME {
    const ticks: u64 = @intCast(@divFloor(nanos, 100) + EPOCH_DIFF);
    return .{
        .dwLowDateTime = @truncate(ticks),
        .dwHighDateTime = @truncate(ticks >> 32),
    };
}

// IOCP functions
pub extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: HANDLE,
    ExistingCompletionPort: ?HANDLE,
    CompletionKey: ULONG_PTR,
    NumberOfConcurrentThreads: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GetQueuedCompletionStatusEx(
    CompletionPort: HANDLE,
    lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: ULONG,
    ulNumEntriesRemoved: *ULONG,
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

// Thread/process functions
pub extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

// APC functions
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

// Console functions
pub extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?HANDLER_ROUTINE,
    Add: BOOL,
) callconv(.winapi) BOOL;

// Directory functions (ntdll)
pub extern "ntdll" fn NtQueryDirectoryFile(
    FileHandle: HANDLE,
    Event: ?HANDLE,
    ApcRoutine: ?*anyopaque,
    ApcContext: ?*anyopaque,
    IoStatusBlock: *IO_STATUS_BLOCK,
    FileInformation: [*]u8,
    Length: ULONG,
    FileInformationClass: FILE_INFORMATION_CLASS,
    ReturnSingleEntry: BOOLEAN,
    FileName: ?*anyopaque,
    RestartScan: BOOLEAN,
) callconv(.winapi) NTSTATUS;

// Time functions (ntdll)
pub extern "ntdll" fn RtlGetSystemTimePrecise() callconv(.winapi) LARGE_INTEGER;
pub extern "ntdll" fn RtlQueryPerformanceCounter(PerformanceCounter: *LARGE_INTEGER) callconv(.winapi) BOOL;
pub extern "ntdll" fn RtlQueryPerformanceFrequency(PerformanceFrequency: *LARGE_INTEGER) callconv(.winapi) BOOL;

// Stack management (ntdll)
pub const INITIAL_TEB = extern struct {
    OldStackBase: PVOID,
    OldStackLimit: PVOID,
    StackBase: PVOID,
    StackLimit: PVOID,
    StackAllocationBase: PVOID,
};

pub extern "ntdll" fn RtlCreateUserStack(
    CommittedStackSize: SIZE_T,
    MaximumStackSize: SIZE_T,
    ZeroBits: ULONG_PTR,
    PageSize: SIZE_T,
    ReserveAlignment: ULONG_PTR,
    InitialTeb: *INITIAL_TEB,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn RtlFreeUserStack(
    StackAllocationBase: PVOID,
) callconv(.winapi) void;

// Handle management
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

// File deletion
pub extern "kernel32" fn DeleteFileW(lpFileName: LPCWSTR) callconv(.winapi) BOOL;

// Path utilities (shlwapi)
pub extern "shlwapi" fn PathIsRelativeW(pszPath: LPCWSTR) callconv(.winapi) BOOL;

// File path resolution
pub extern "kernel32" fn GetFinalPathNameByHandleW(
    hFile: HANDLE,
    lpszFilePath: [*]WCHAR,
    cchFilePath: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) DWORD;

// GetFinalPathNameByHandle flags
pub const FILE_NAME_NORMALIZED: DWORD = 0x0;
pub const VOLUME_NAME_DOS: DWORD = 0x0;

// Code page constants
pub const CP_UTF8: DWORD = 65001;

pub extern "kernel32" fn MultiByteToWideChar(
    CodePage: DWORD,
    dwFlags: DWORD,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: c_int,
    lpWideCharStr: ?[*]WCHAR,
    cchWideChar: c_int,
) callconv(.winapi) c_int;

// Re-export helper functions from std.os.windows
pub const peb = std.os.windows.peb;

// Win32 error codes (copied from Zig std)
pub const Win32Error = @import("windows/win32error.zig").Win32Error;

/// Query the performance counter (monotonic clock ticks).
pub fn QueryPerformanceCounter() u64 {
    var result: LARGE_INTEGER = undefined;
    std.debug.assert(RtlQueryPerformanceCounter(&result) != 0);
    return @bitCast(result);
}

/// Query the performance counter frequency (ticks per second).
pub fn QueryPerformanceFrequency() u64 {
    var result: LARGE_INTEGER = undefined;
    std.debug.assert(RtlQueryPerformanceFrequency(&result) != 0);
    return @bitCast(result);
}

// Error handling
pub extern "kernel32" fn GetLastError() callconv(.winapi) Win32Error;

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

pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;

// ============================================================================
// Winsock types and functions
// ============================================================================

pub const WORD = std.os.windows.WORD;
pub const SHORT = std.os.windows.SHORT;
pub const INT = std.os.windows.INT;

pub const SOCKET = std.os.windows.ws2_32.SOCKET;
pub const INVALID_SOCKET = std.os.windows.ws2_32.INVALID_SOCKET;
pub const SOCKET_ERROR: i32 = -1;

pub const ADDRESS_FAMILY = u16;
pub const socklen_t = u32;

pub const sockaddr = extern struct {
    family: ADDRESS_FAMILY,
    data: [14]u8,

    pub const SS_MAXSIZE = 128;

    pub const storage = extern struct {
        family: ADDRESS_FAMILY align(8),
        padding: [SS_MAXSIZE - @sizeOf(ADDRESS_FAMILY)]u8 = undefined,
    };

    pub const in = extern struct {
        family: ADDRESS_FAMILY = AF.INET,
        port: u16,
        addr: u32,
        zero: [8]u8 = [_]u8{0} ** 8,
    };

    pub const in6 = extern struct {
        family: ADDRESS_FAMILY = AF.INET6,
        port: u16,
        flowinfo: u32 = 0,
        addr: [16]u8,
        scope_id: u32 = 0,
    };

    pub const un = extern struct {
        family: ADDRESS_FAMILY = AF.UNIX,
        path: [108]u8,
    };
};

// Forward from std to maintain compatibility with std.Io.Reader
pub const WSABUF = std.os.windows.ws2_32.WSABUF;
pub const LPWSAOVERLAPPED_COMPLETION_ROUTINE = std.os.windows.ws2_32.LPWSAOVERLAPPED_COMPLETION_ROUTINE;

// WSAMSG structures for WSARecvMsg/WSASendMsg
// WSABUF with optional buf pointer for Control field
pub const WSABUF_nullable = extern struct {
    len: ULONG,
    buf: ?[*]u8,
};

pub const WSAMSG = extern struct {
    name: ?*sockaddr,
    namelen: i32,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    Control: WSABUF_nullable,
    dwFlags: u32,
};

pub const WSAMSG_const = extern struct {
    name: ?*const sockaddr,
    namelen: i32,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    Control: WSABUF_nullable,
    dwFlags: u32,
};

pub const pollfd = extern struct {
    fd: SOCKET,
    events: SHORT,
    revents: SHORT,
};

pub const WSADESCRIPTION_LEN = 256;
pub const WSASYS_STATUS_LEN = 128;

pub const WSADATA = if (@sizeOf(usize) == @sizeOf(u64))
    extern struct {
        wVersion: WORD,
        wHighVersion: WORD,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?*u8,
        szDescription: [WSADESCRIPTION_LEN + 1]u8,
        szSystemStatus: [WSASYS_STATUS_LEN + 1]u8,
    }
else
    extern struct {
        wVersion: WORD,
        wHighVersion: WORD,
        szDescription: [WSADESCRIPTION_LEN + 1]u8,
        szSystemStatus: [WSASYS_STATUS_LEN + 1]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?*u8,
    };

// Poll events
pub const POLL = struct {
    pub const RDNORM: SHORT = 256;
    pub const RDBAND: SHORT = 512;
    pub const PRI: SHORT = 1024;
    pub const WRNORM: SHORT = 16;
    pub const WRBAND: SHORT = 32;
    pub const ERR: SHORT = 1;
    pub const HUP: SHORT = 2;
    pub const NVAL: SHORT = 4;
    pub const IN: SHORT = RDNORM | RDBAND;
    pub const OUT: SHORT = WRNORM;
};

// Message flags
pub const MSG = struct {
    pub const PEEK: u32 = 2;
    pub const WAITALL: u32 = 8;
};

// Shutdown modes
pub const SD_RECEIVE: i32 = 0;
pub const SD_SEND: i32 = 1;
pub const SD_BOTH: i32 = 2;

// Socket flags
pub const WSA_FLAG_OVERLAPPED: u32 = 1;

// ioctlsocket commands
pub const FIONBIO: i32 = -2147195266;

// Address info flags
pub const AI = packed struct(u32) {
    PASSIVE: bool = false,
    CANONNAME: bool = false,
    NUMERICHOST: bool = false,
    NUMERICSERV: bool = false,
    DNS_ONLY: bool = false,
    _5: u3 = 0,
    ALL: bool = false,
    _9: u1 = 0,
    ADDRCONFIG: bool = false,
    V4MAPPED: bool = false,
    _12: u2 = 0,
    NON_AUTHORITATIVE: bool = false,
    SECURE: bool = false,
    RETURN_PREFERRED_NAMES: bool = false,
    FQDN: bool = false,
    FILESERVER: bool = false,
    DISABLE_IDN_ENCODING: bool = false,
    _20: u10 = 0,
    RESOLUTION_HANDLE: bool = false,
    EXTENDED: bool = false,
};

// Winsock functions
pub extern "ws2_32" fn WSAStartup(
    wVersionRequired: WORD,
    lpWSAData: *WSADATA,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSAPoll(
    fdArray: [*]pollfd,
    fds: u32,
    timeout: i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;

pub extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;

pub extern "ws2_32" fn WSASocketW(
    af: i32,
    type_: i32,
    protocol: i32,
    lpProtocolInfo: ?*anyopaque,
    g: u32,
    dwFlags: u32,
) callconv(.winapi) SOCKET;

pub extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.winapi) i32;

pub extern "ws2_32" fn bind(s: SOCKET, name: *const sockaddr, namelen: i32) callconv(.winapi) i32;

pub extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;

pub extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr, namelen: i32) callconv(.winapi) i32;

pub extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr, addrlen: ?*i32) callconv(.winapi) SOCKET;

pub extern "ws2_32" fn getsockname(s: SOCKET, name: *sockaddr, namelen: *i32) callconv(.winapi) i32;

pub extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(.winapi) i32;

pub extern "ws2_32" fn WSARecv(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesRecvd: ?*u32,
    lpFlags: *u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSASend(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesSent: ?*u32,
    dwFlags: u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSARecvFrom(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesRecvd: ?*u32,
    lpFlags: *u32,
    lpFrom: ?*sockaddr,
    lpFromlen: ?*i32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSASendTo(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesSent: ?*u32,
    dwFlags: u32,
    lpTo: ?*const sockaddr,
    iToLen: i32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn setsockopt(
    s: SOCKET,
    level: i32,
    optname: u32,
    optval: ?[*]const u8,
    optlen: i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSAIoctl(
    s: SOCKET,
    dwIoControlCode: DWORD,
    lpvInBuffer: ?*const anyopaque,
    cbInBuffer: DWORD,
    lpvOutBuffer: ?*anyopaque,
    cbOutBuffer: DWORD,
    lpcbBytesReturned: *DWORD,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSAGetOverlappedResult(
    s: SOCKET,
    lpOverlapped: *OVERLAPPED,
    lpcbTransfer: *DWORD,
    fWait: BOOL,
    lpdwFlags: *DWORD,
) callconv(.winapi) BOOL;

// GUID type
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// Address families
pub const AF = struct {
    pub const UNSPEC: u16 = 0;
    pub const UNIX: u16 = 1;
    pub const INET: u16 = 2;
    pub const INET6: u16 = 23;
};

// Socket types
pub const SOCK = struct {
    pub const STREAM: i32 = 1;
    pub const DGRAM: i32 = 2;
    pub const RAW: i32 = 3;
    pub const SEQPACKET: i32 = 5;
};

// Socket option levels
pub const SOL = struct {
    pub const SOCKET: i32 = 0xffff;
};

// Socket options (SOL_SOCKET level)
pub const SO = struct {
    pub const REUSEADDR: i32 = 0x0004;
    pub const KEEPALIVE: i32 = 0x0008;
    pub const ERROR: i32 = 0x1007;
};

// TCP options (IPPROTO_TCP level)
pub const TCP = struct {
    pub const NODELAY: i32 = 0x0001;
};

// Winsock-specific socket options
pub const SO_UPDATE_ACCEPT_CONTEXT: i32 = 0x700b;
pub const SO_UPDATE_CONNECT_CONTEXT: i32 = 0x7010;

// WSAIoctl codes
pub const SIO_GET_EXTENSION_FUNCTION_POINTER: DWORD = 0xc8000006;

/// Errors that can occur when converting a path to wide string.
pub const PathToWideError = error{
    SystemResources,
    NameTooLong,
    Unexpected,
};

/// Converts a (dir_handle, UTF-8 path) pair to an absolute null-terminated wide string.
/// If dir is FDCWD, the path is converted directly (kernel32 APIs resolve against CWD).
/// Otherwise, resolves the path relative to the directory handle.
/// Caller must free the returned slice with the same allocator.
pub fn pathToWide(allocator: std.mem.Allocator, dir: HANDLE, path: []const u8) PathToWideError![:0]WCHAR {
    // Convert path to wide first - we need this in all cases
    const path_wide = try utf8ToWide(allocator, path);

    // If CWD or path is absolute, just return the converted path
    if (dir == FDCWD or PathIsRelativeW(path_wide) == FALSE) {
        return path_wide;
    }
    defer allocator.free(path_wide);

    // Non-CWD with relative path: get directory path, then join

    // Get the directory's absolute path
    // Start with a reasonable buffer, grow if needed
    var dir_buf: [512]WCHAR = undefined;
    var dir_path: []const WCHAR = undefined;
    var heap_dir_buf: ?[]WCHAR = null;
    defer if (heap_dir_buf) |buf| allocator.free(buf);

    var result = GetFinalPathNameByHandleW(dir, &dir_buf, dir_buf.len, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (result == 0) {
        return switch (GetLastError()) {
            .NOT_ENOUGH_MEMORY => error.SystemResources,
            else => error.Unexpected,
        };
    } else if (result > dir_buf.len) {
        // Buffer too small, allocate on heap
        heap_dir_buf = allocator.alloc(WCHAR, result) catch return error.SystemResources;
        result = GetFinalPathNameByHandleW(dir, heap_dir_buf.?.ptr, @intCast(heap_dir_buf.?.len), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (result == 0) {
            return switch (GetLastError()) {
                .NOT_ENOUGH_MEMORY => error.SystemResources,
                else => error.Unexpected,
            };
        } else if (result > heap_dir_buf.?.len) {
            return error.Unexpected; // Buffer size changed between calls
        }
        dir_path = heap_dir_buf.?[0..result];
    } else {
        dir_path = dir_buf[0..result];
    }

    // Join: dir_path + '\' + path_wide + null
    // dir_path from GetFinalPathNameByHandleW has \\?\ prefix and no trailing slash
    const total_len = dir_path.len + 1 + path_wide.len;
    const joined = allocator.allocSentinel(WCHAR, total_len, 0) catch return error.SystemResources;

    @memcpy(joined[0..dir_path.len], dir_path);
    joined[dir_path.len] = '\\';
    @memcpy(joined[dir_path.len + 1 ..][0..path_wide.len], path_wide);

    return joined;
}

/// Converts UTF-8 string to null-terminated wide string.
/// Caller must free the returned slice with the same allocator.
fn utf8ToWide(allocator: std.mem.Allocator, utf8: []const u8) PathToWideError![:0]WCHAR {
    if (utf8.len == 0) {
        return allocator.allocSentinel(WCHAR, 0, 0) catch return error.SystemResources;
    }

    // Get required buffer size
    const len = MultiByteToWideChar(
        CP_UTF8,
        0,
        utf8.ptr,
        @intCast(utf8.len),
        null,
        0,
    );
    if (len <= 0) {
        return switch (GetLastError()) {
            .INSUFFICIENT_BUFFER => error.NameTooLong,
            else => error.Unexpected,
        };
    }

    // Allocate and convert
    const wide = allocator.allocSentinel(WCHAR, @intCast(len), 0) catch return error.SystemResources;
    const result = MultiByteToWideChar(
        CP_UTF8,
        0,
        utf8.ptr,
        @intCast(utf8.len),
        wide.ptr,
        len,
    );
    if (result <= 0) {
        allocator.free(wide);
        return switch (GetLastError()) {
            .INSUFFICIENT_BUFFER => error.NameTooLong,
            else => error.Unexpected,
        };
    }

    return wide;
}
