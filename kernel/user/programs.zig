// The M3 user-mode programs (03-syscall-abi.md; 08-roadmap.md M3). Two tiny EL0 clients that prove the syscall and
// IPC spine end to end: a client `call`s a server over a badged endpoint, passing a Region handle; the server maps
// that region, reads a magic word the client wrote, and replies with the magic and the badge it observed.
//
// They are hand-written, position-independent assembly with no data references or literal pools, placed in the
// `.user_text` section. The kernel copies that whole section verbatim into a fresh Region and maps it into each
// process at an arbitrary user VA (config.user_space_base); because every reference here is register/immediate or a
// PC-relative branch within the blob, the copy runs correctly wherever it lands - no loader or relocations (M4/M6).
//
// Calling convention (03-syscall-abi.md): number in x8, arguments x0..x5, result in x0. Sentinels: SELF_SPACE =
// 0xffff_fffd, SELF_THREAD = 0xffff_fffe. Verb numbers match syscall.Number. Each program receives a pointer to its
// bootinfo block in x0 (the layouts below), from which it reads its handles and parameters.

// Kept in sync with the assembly and the kernel overseer (main.zig).

pub const client_badge: u64 = 0x00C0_FFEE;
pub const magic: u64 = 0xCAFE_F00D;
pub const iterations: u64 = 1000;

/// Client bootinfo, filled by the kernel; the trailing result fields are written back by the client for the overseer.
pub const ClientBootinfo = extern struct {

    endpoint: u64, // badged handle to the shared endpoint
    data_region: u64, // handle to the shared data Region
    done: u64, // handle to the completion Notification
    map_at: u64, // VA at which to map the data Region

    iterations: u64,

    result_status: u64,
    result_badge: u64,
    result_magic: u64,
    result_ns: u64, // total nanoseconds across all round-trips

};

/// Server bootinfo.
pub const ServerBootinfo = extern struct {

    endpoint: u64, // handle to the shared endpoint
    map_at: u64, // VA at which to map a received Region

};

// The client: map the shared region, write the magic, then time `iterations` call/reply round-trips, each passing the
// region handle. Record status, observed badge, echoed magic, and elapsed nanoseconds, signal `done`, and exit.

pub fn user_client() linksection(".user_text") callconv(.naked) void {

    asm volatile (
        \\ mov  x19, x0                 // bootinfo
        \\ ldr  x20, [x19, #0]          // endpoint (badged)
        \\ ldr  x21, [x19, #8]          // data region handle
        \\ ldr  x22, [x19, #24]         // map_at
        \\ ldr  x23, [x19, #32]         // iterations
        \\ sub  sp, sp, #96             // message buffer
        \\
        \\ mov  x0, #0xfffd             // map(SELF_SPACE, region, map_at, read|write)
        \\ movk x0, #0xffff, lsl #16
        \\ mov  x1, x21
        \\ mov  x2, x22
        \\ mov  x3, #3
        \\ mov  x8, #7
        \\ svc  #0
        \\
        \\ movz x9, #0xf00d             // magic 0xCAFEF00D
        \\ movk x9, #0xcafe, lsl #16
        \\ str  x9, [x22]               // data_region[0] = magic
        \\
        \\ isb
        \\ mrs  x24, cntpct_el0         // start
        \\ mov  x25, #0                 // iteration counter
        \\
        \\1:
        \\ mov  x9, #1
        \\ str  x9, [sp, #0]            // data[0] = method
        \\ str  w21, [sp, #48]          // handles[0].handle = data region
        \\ strb wzr, [sp, #52]          // handles[0].move = 0 (copy)
        \\ mov  w9, #1
        \\ str  w9, [sp, #84]           // handle_count = 1
        \\ mov  x0, x20                 // call(endpoint, msg)
        \\ mov  x1, sp
        \\ mov  x8, #11
        \\ svc  #0
        \\ add  x25, x25, #1
        \\ cmp  x25, x23
        \\ b.lo 1b
        \\
        \\ isb
        \\ mrs  x26, cntpct_el0         // end
        \\
        \\ ldr  x9, [sp, #0]            // reply data[0] = status
        \\ str  x9, [x19, #40]
        \\ ldr  x9, [sp, #16]           // reply data[2] = observed badge
        \\ str  x9, [x19, #48]
        \\ ldr  x9, [sp, #8]            // reply data[1] = echoed magic
        \\ str  x9, [x19, #56]
        \\
        \\ sub  x9, x26, x24            // elapsed ticks
        \\ mrs  x10, cntfrq_el0
        \\ movz x11, #0xca00            // 1_000_000_000
        \\ movk x11, #0x3b9a, lsl #16
        \\ mul  x9, x9, x11
        \\ udiv x9, x9, x10             // total nanoseconds
        \\ str  x9, [x19, #64]
        \\
        \\ ldr  x0, [x19, #16]          // notify(done, 1)
        \\ mov  x1, #1
        \\ mov  x8, #13
        \\ svc  #0
        \\
        \\ mov  x0, #0xfffe             // close(SELF_THREAD) - exit
        \\ movk x0, #0xffff, lsl #16
        \\ mov  x8, #3
        \\ svc  #0
        \\
        \\2:
        \\ b    2b
    );

}

// The server loop: receive a request, map the passed region, read the magic, and reply with status/magic/badge.
// It unmaps and closes the received handle each round so its address space and handle table do not grow.

pub fn user_server() linksection(".user_text") callconv(.naked) void {

    asm volatile (
        \\ mov  x19, x0                 // bootinfo
        \\ ldr  x20, [x19, #0]          // endpoint
        \\ ldr  x21, [x19, #8]          // map_at
        \\ sub  sp, sp, #96             // message buffer
        \\
        \\1:
        \\ mov  x0, x20                 // receive(endpoint, msg)
        \\ mov  x1, sp
        \\ mov  x8, #10
        \\ svc  #0
        \\ mov  x22, x0                 // badge
        \\ ldr  w23, [sp, #48]          // received region handle
        \\ ldr  w24, [sp, #80]          // one-shot reply handle
        \\
        \\ mov  x0, #0xfffd             // map(SELF_SPACE, region, map_at, read)
        \\ movk x0, #0xffff, lsl #16
        \\ mov  x1, x23
        \\ mov  x2, x21
        \\ mov  x3, #1
        \\ mov  x8, #7
        \\ svc  #0
        \\
        \\ ldr  x25, [x21]              // read the magic word
        \\
        \\ str  xzr, [sp, #0]           // reply data[0] = status 0
        \\ str  x25, [sp, #8]           // reply data[1] = magic
        \\ str  x22, [sp, #16]          // reply data[2] = badge
        \\ str  wzr, [sp, #84]          // handle_count = 0
        \\
        \\ mov  x0, #0xfffd             // unmap(SELF_SPACE, map_at)
        \\ movk x0, #0xffff, lsl #16
        \\ mov  x1, x21
        \\ mov  x8, #8
        \\ svc  #0
        \\
        \\ mov  w0, w23                 // close(received region handle)
        \\ mov  x8, #3
        \\ svc  #0
        \\
        \\ mov  w0, w24                 // reply(reply_handle, msg)
        \\ mov  x1, sp
        \\ mov  x8, #12
        \\ svc  #0
        \\
        \\ b    1b
    );

}
