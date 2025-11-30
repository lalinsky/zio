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
