// aarch64 CPU control: identity, barriers, and the low-power wait (the slice of 06-kernel-ddd.md Section 5 M0 needs).

const build_options = @import("build_options");

pub fn core_id() u32 {

    const mpidr = asm volatile ("mrs %[out], mpidr_el1"

        : [out] "=r" (-> u64),

    );

    return @truncate(mpidr & 0xff);

}

pub fn wait_for_event() void {

    asm volatile ("wfe");

}

/// Park until an IRQ is pending; the idle loop uses this with the timer disarmed when nothing is runnable.
pub fn wait_for_interrupt() void {

    asm volatile ("wfi");

}

pub fn send_event() void {

    asm volatile ("sev");

}

/// Open CPACR_EL1.FPEN for EL0 FP/SIMD; `switch.S` re-disables when switching to a thread that never trapped in.
pub fn enable_fp_el0() void {

    var cpacr = asm volatile ("mrs %[out], cpacr_el1"
        : [out] "=r" (-> u64),
    );

    cpacr |= @as(u64, 3) << 20;

    asm volatile (
        \\ msr cpacr_el1, %[value]
        \\ isb
        :
        : [value] "r" (cpacr),
        : .{ .memory = true });

}

/// Make freshly written instructions visible to the fetch path (after copying user code into a mapped page).
pub fn sync_instruction_cache() void {

    asm volatile (
        \\ dsb ish
        \\ ic iallu
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });

}

/// Clean/invalidate identity-mapped cache lines before remapping recycled RAM as uncached DMA, so stale writes cannot clobber device rings.
pub fn clean_invalidate_data_cache(base: usize, length: usize) void {

    if (length == 0) return;

    const ctr = asm volatile ("mrs %[out], ctr_el0"
        : [out] "=r" (-> u64),
    );

    const shift: u6 = @intCast((ctr >> 16) & 0xf);
    const line_size = @as(usize, 4) << shift;
    const mask = line_size - 1;

    var address = base & ~mask;
    const end = (base + length + mask) & ~mask;

    while (address < end) : (address += line_size) {

        asm volatile ("dc civac, %[addr]"
            :
            : [addr] "r" (address),
            : .{ .memory = true });

    }

    asm volatile ("dsb ish" ::: .{ .memory = true });

}

// The prior IRQ-mask state, so nested disable/restore pairs compose (06-kernel-ddd.md Section 5).

pub const InterruptState = usize;

pub fn enable_interrupts() void {

    asm volatile ("msr daifclr, #2");

}

pub fn disable_interrupts() InterruptState {

    const daif = asm volatile ("mrs %[out], daif"

        : [out] "=r" (-> u64),

    );

    asm volatile ("msr daifset, #2");

    return daif;

}

pub fn restore_interrupts(state: InterruptState) void {

    asm volatile ("msr daif, %[value]"
        :
        : [value] "r" (state),
    );

}

/// Mask all interrupts and stop this core for good; the test build instead asks QEMU to exit so the check terminates.
pub fn halt() noreturn {

    if (build_options.@"test") {

        semihosting_exit(0);

    }

    asm volatile ("msr daifset, #0xf");

    while (true) {

        asm volatile ("wfe");

    }

}

/// Park quietly on the halt IPI: no semihosting exit so the panicking core keeps the console and QEMU exit in test builds.
pub fn park() noreturn {

    asm volatile ("msr daifset, #0xf");

    while (true) {

        asm volatile ("wfe");

    }

}

// Angel SYS_EXIT semihosting call: with `-semihosting`, QEMU exits (0x2_0026 is the required ApplicationExit reason).
fn semihosting_exit(code: u64) noreturn {

    var block = [2]u64{ 0x2_0026, code };

    asm volatile ("hlt #0xf000"
        :
        : [operation] "{x0}" (@as(u64, 0x18)),
          [parameter] "{x1}" (&block),
        : .{ .memory = true }
    );

    unreachable;

}
