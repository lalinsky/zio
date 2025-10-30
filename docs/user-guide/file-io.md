# File I/O

ZIO provides asynchronous file operations. On Linux and Windows, file I/O is truly async using io_uring and IOCP. On other platforms, operations are simulated using a thread pool.

## Opening Files

### Open for Reading

```zig
const std = @import("std");
const zio = @import("zio");

fn readFile(rt: *zio.Runtime) !void {
    var file = try zio.fs.openFile(rt, "input.txt", .{
        .mode = .read_only,
    });
    defer file.close(rt);

    // Read from file...
}
```

### Create or Open for Writing

```zig
fn writeFile(rt: *zio.Runtime) !void {
    var file = try zio.fs.createFile(rt, "output.txt", .{
        .truncate = true,  // Truncate if exists (default)
    });
    defer file.close(rt);

    // Write to file...
}
```

### Open with Custom Options

```zig
var file = try zio.fs.openFile(rt, "data.txt", .{
    .mode = .read_write,
    .create = true,      // Create if doesn't exist
    .truncate = false,   // Don't truncate if exists
    .exclusive = false,  // Fail if file exists (with create = true)
});
```

## Reading Files

### Raw Read

```zig
fn readData(rt: *zio.Runtime, file: *zio.fs.File) !void {
    var buffer: [4096]u8 = undefined;

    // Read up to buffer.len bytes
    const bytes_read = try file.read(rt, &buffer);

    std.log.info("Read {} bytes", .{bytes_read});
}
```

### Read All

```zig
// Read until buffer is full or EOF
const bytes_read = try file.readAll(rt, &buffer);
```

### Buffered Reader

Use standard `std.Io.Reader` interface:

```zig
fn readLines(rt: *zio.Runtime, file: *zio.fs.File, allocator: std.mem.Allocator) !void {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(rt, &buffer);

    // Read line by line
    while (true) {
        const line = reader.interface.readUntilDelimiterOrEof(&buffer, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (line) |data| {
            std.log.info("Line: {s}", .{data});
        } else break;
    }
}
```

### Read Entire File

```zig
fn readEntireFile(rt: *zio.Runtime, allocator: std.mem.Allocator) ![]u8 {
    var file = try zio.fs.openFile(rt, "data.txt", .{ .mode = .read_only });
    defer file.close(rt);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(rt, &buffer);

    // Read all content into dynamic buffer
    const content = try reader.interface.readAllAlloc(allocator, std.math.maxInt(usize));
    return content;
}
```

## Writing Files

### Raw Write

```zig
fn writeData(rt: *zio.Runtime, file: *zio.fs.File, data: []const u8) !void {
    // Write some bytes
    const bytes_written = try file.write(rt, data);

    std.log.info("Wrote {} bytes", .{bytes_written});
}
```

### Write All

```zig
// Ensure all bytes are written
try file.writeAll(rt, data);
```

### Buffered Writer

Use standard `std.Io.Writer` interface:

```zig
fn writeLines(rt: *zio.Runtime, file: *zio.fs.File) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(rt, &buffer);

    // Write formatted output
    try writer.interface.print("Hello, {}!\n", .{"world"});
    try writer.interface.writeAll("Another line\n");

    // Don't forget to flush!
    try writer.interface.flush();
}
```

## File Positioning

### Seek

```zig
// Seek to absolute position
try file.seekTo(rt, 100);

// Seek relative to current position
try file.seekBy(rt, 50);

// Get current position
const pos = try file.getPos(rt);
std.log.info("Current position: {}", .{pos});

// Get file size
const size = try file.getEndPos(rt);
std.log.info("File size: {}", .{size});
```

## File Metadata

```zig
const stat = try zio.fs.stat(rt, "myfile.txt");

std.log.info("Size: {}", .{stat.size});
std.log.info("Modified: {}", .{stat.mtime});
std.log.info("Is directory: {}", .{stat.kind == .directory});
```

## Directory Operations

### List Directory

```zig
fn listDir(rt: *zio.Runtime, allocator: std.mem.Allocator) !void {
    var dir = try zio.fs.openDir(rt, "/path/to/dir");
    defer dir.close(rt);

    var iter = dir.iterate();
    while (try iter.next(rt)) |entry| {
        std.log.info("Entry: {s} ({})", .{ entry.name, entry.kind });
    }
}
```

### Create Directory

```zig
try zio.fs.makeDir(rt, "/path/to/newdir");

// Create with parents
try zio.fs.makePath(rt, "/path/to/nested/dirs");
```

### Remove Files/Directories

```zig
// Remove file
try zio.fs.deleteFile(rt, "file.txt");

// Remove empty directory
try zio.fs.deleteDir(rt, "emptydir");

// Remove directory tree
try zio.fs.deleteTree(rt, "dirwithcontents");
```

## Complete Example

Reading and processing a file line by line:

```zig
const std = @import("std");
const zio = @import("zio");

fn processFile(rt: *zio.Runtime, allocator: std.mem.Allocator) !void {
    // Open input file
    var input = try zio.fs.openFile(rt, "input.txt", .{ .mode = .read_only });
    defer input.close(rt);

    // Create output file
    var output = try zio.fs.createFile(rt, "output.txt", .{});
    defer output.close(rt);

    // Set up readers/writers
    var read_buffer: [4096]u8 = undefined;
    var reader = input.reader(rt, &read_buffer);

    var write_buffer: [4096]u8 = undefined;
    var writer = output.writer(rt, &write_buffer);

    // Process line by line
    var line_num: u32 = 0;
    while (true) {
        const line = reader.interface.readUntilDelimiterOrEof(&read_buffer, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (line) |data| {
            line_num += 1;

            // Transform and write
            try writer.interface.print("{}: {s}\n", .{ line_num, data });
        } else break;
    }

    // Flush output
    try writer.interface.flush();

    std.log.info("Processed {} lines", .{line_num});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    try rt.runUntilComplete(processFile, .{ rt, gpa.allocator() }, .{});
}
```

## Platform Differences

### Linux
- Uses **io_uring** for true async file I/O
- All operations are non-blocking
- Excellent performance

### Windows
- Uses **IOCP** (I/O Completion Ports)
- True async for most operations
- Good performance

### macOS / BSD
- Uses **thread pool** to simulate async I/O
- Operations block worker threads
- Still non-blocking from coroutine perspective

## Error Handling

Common file I/O errors:

```zig
file.read(rt, buffer) catch |err| switch (err) {
    error.FileNotFound => {
        // File doesn't exist
    },
    error.AccessDenied => {
        // Permission denied
    },
    error.EndOfStream => {
        // Reached end of file
    },
    error.Canceled => {
        // Operation was canceled
    },
    else => return err,
};
```

## Best Practices

### 1. Always Close Files

Use `defer` for automatic cleanup:

```zig
var file = try zio.fs.openFile(rt, "data.txt", .{ .mode = .read_only });
defer file.close(rt);
```

### 2. Flush Buffered Writers

Don't forget to flush:

```zig
try writer.interface.writeAll(data);
try writer.interface.flush();  // Important!
```

### 3. Use Buffered I/O

For line-by-line or formatted I/O, always use buffered readers/writers:

```zig
var buffer: [4096]u8 = undefined;
var reader = file.reader(rt, &buffer);
```

### 4. Handle EOF Properly

Check for end of file:

```zig
const data = reader.interface.readUntilDelimiterOrEof(&buffer, '\n') catch |err| switch (err) {
    error.EndOfStream => return,
    else => return err,
};

if (data == null) {
    // EOF reached
}
```

### 5. Choose Buffer Sizes Wisely

```zig
// Small files or line-by-line
var buffer: [4096]u8 = undefined;

// Large file transfers
var buffer: [65536]u8 = undefined;
```

## Next Steps

- [Examples](https://github.com/lalinsky/zio/tree/main/examples) - See complete examples
- [Runtime & Tasks](runtime.md) - Learn more about the runtime
