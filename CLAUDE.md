# Project Structure

Prefer clean modules with straightforward, single-word directory names (`arch`,
`board`, `debug`, …). Keep names plain and concrete.

**Never mix assembly and Zig in the same directory.** A module directory is
either Zig sources or it is not. Each architecture keeps all of its non-Zig
toolchain inputs — `.S` sources and the linker script — in an `asm/`
subdirectory, so the arch directory itself stays Zig-only.

# Code Style

## Zig

### Spacing and Braces

Every block delimited by `{...}` gets a blank line after the opening brace and before the closing brace. This applies universally: function bodies, struct bodies, `if`/`for`/`while`/`switch` blocks, struct literals, and anonymous function literals.

```zig
fn allocatePage(self: *MemoryManager, flags: PageFlags) !PhysAddr {

    const frame = self.free_list.pop() orelse return error.OutOfMemory;

    if (!flags.writable) {

        try self.map(frame, .read_only);

    } else {

        try self.map(frame, flags);

    }

    return frame.base_addr;

}
```

The only exception is `error{...}` sets — these do not get inner blank lines.

### Error Handling

Prefer `try` for propagating errors — it is the idiomatic early-return in Zig. Use `catch` only when you need to transform the error, log it, or recover. Each explicit `catch` block follows the same blank-line pattern as any other block:

```zig
const frame = allocator.create(Frame) catch |err| {

    log.err("frame alloc failed: {}", .{err});
    return err;

};
```

Avoid `catch unreachable` except where the invariant is truly guaranteed by surrounding logic.

### Struct Declarations

Struct fields are not horizontally aligned. No extra spaces to align types or default values across lines:

```zig
// Correct
const Thread = struct {

    id: u32,
    state: ThreadState,

    stack_base: usize,
    stack_size: usize,

    context: CpuContext,

};

// Wrong — do not align
const Thread = struct {
    id         : u32,
    state      : ThreadState,
    stack_base : usize,
    stack_size : usize,
    context    : CpuContext,
};
```

### Const and Var Declarations

No alignment of `=` signs across declarations. Error sets are declared as named types:

```zig
// Correct
const AllocError = error{
    
    OutOfMemory,
    InvalidAlignment,
    Fragmented,
    
};

const page_size = 4096;
const max_threads = 256;
const kernel_base = 0xffff_8000_0000_0000;
```

### Imports

Group `@import` calls in this order, each group separated by a blank line:

1. Standard library (`std`, `builtin`)
2. Internal modules (relative paths — kernel, servers, HAL)
3. External packages

```zig
const std = @import("std");
const builtin = @import("builtin");

const kernel = @import("./kernel/root.zig");
const ipc = @import("./kernel/ipc.zig");
const hal = @import("./hal/root.zig");

const dtb = @import("dtb");
```

### Struct Literals

Struct literals follow the same blank-line rule as blocks. Related fields should be grouped together with blank lines between groups, but no extra spaces to align field names or values:

```zig
const thread = Thread{

    .id = next_id,
    .state = .ready,

    .stack_base = stack.base,
    .stack_size = stack_size,

    .context = std.mem.zeroes(CpuContext),

};
```

### Comments

Add comments only when the *why* is non-obvious — a hidden constraint, a workaround, or surprising behavior. Never describe what the code does (well-named identifiers do that). One short line maximum; no multi-line comment blocks. Use `///` doc comments only on public API items.

### General Rules

- No trailing whitespace on any line
- Consistent 4-space indentation (`zig fmt` standard)
- Blank lines between distinct statement groups within a function body
- Short one-liner functions are acceptable only when the entire function fits on a single line
