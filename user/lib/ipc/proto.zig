// Shared interface constants (07-userspace-ddd.md Section 3.4, Section 10; 05-server-protocol.md): word 0 is method in, status out; method 0 is always Identify; methods are append-only.

pub const identify: u16 = 0;

// The Stream interface (07-userspace-ddd.md Section 10.2), spoken by the console driver (and later pipes and
// terminals). `attach` extends the table with the per-session shared buffer setup of 05-server-protocol.md:
// the client shares one Region up front, and every read/write after that passes only offset/length into it.

pub const stream = struct {

    pub const interface_id: u32 = 0x5354_524d; // "STRM"
    pub const version: u32 = 1;

    pub const read: u16 = 1; // request: offset, capacity        reply: bytes read
    pub const write: u16 = 2; // request: offset, length          reply: bytes written
    pub const set_mode: u16 = 3; // request: mode                    reply: status
    pub const attach: u16 = 4; // request: capacity, buffer Region  reply: status

    pub const mode_raw: u64 = 0;
    pub const mode_cooked: u64 = 1;

};

// Init message consumed by the runtime on cap.startup_endpoint before it calls the program's main.

pub const init = struct {

    pub const stdin_ring: u64 = 1 << 0;
    pub const stdout_ring: u64 = 1 << 1;
    pub const stderr_ring: u64 = 1 << 2;

    // Init message data[5]: the machine's discovered core count, threaded from Flint through Marble.
    pub const core_count_word: usize = 5;

};

// Name service interface (07-userspace-ddd.md Section 10.1), with M6 inline names.

pub const name = struct {

    pub const interface_id: u32 = 0x4e41_4d45; // "NAME"
    pub const version: u32 = 1;

    pub const max_length: usize = 32;

    pub const register: u16 = 1;
    pub const lookup: u16 = 2;
    pub const list: u16 = 3;
    pub const unregister: u16 = 4;

};

// Block interface (07-userspace-ddd.md Section 10.5), spoken by the virtio-blk driver. `attach` extends the table
// with the per-session shared buffer setup of 05-server-protocol.md; sectors then ride at offsets into it.

pub const block = struct {

    pub const interface_id: u32 = 0x424c_4f4b; // "BLOK"
    pub const version: u32 = 1;

    pub const sector_size: usize = 512;

    pub const read_sector: u16 = 1; // request: sector, offset           reply: status
    pub const write_sector: u16 = 2; // request: sector, offset           reply: status
    pub const capacity: u16 = 3; // request: -                        reply: sector count
    pub const attach: u16 = 4; // request: capacity, buffer Region   reply: status

};

// Filesystem interface (07-userspace-ddd.md Section 10.3). Paths, file data, and result records ride in the
// per-session shared buffer as (offset, length) pairs; `attach` (appended) shares that buffer once.

pub const filesystem = struct {

    pub const interface_id: u32 = 0x4653_5652; // "FSVR"
    pub const version: u32 = 1;

    pub const open: u16 = 1; // request: path offset, path length, flags     reply: file id
    pub const close: u16 = 2; // request: file id                             reply: status
    pub const read: u16 = 3; // request: file id, file offset, buffer offset, length   reply: bytes read
    pub const write: u16 = 4; // request: file id, file offset, buffer offset, length   reply: bytes written
    pub const create: u16 = 5; // request: path offset, path length, kind      reply: status
    pub const delete: u16 = 6; // request: path offset, path length            reply: status
    pub const rename: u16 = 7; // request: old offset, old length, new offset, new length   reply: status
    pub const list: u16 = 8; // request: path offset, path length, buffer offset, capacity   reply: bytes written
    pub const stat: u16 = 9; // request: path offset, path length, buffer offset   reply: status
    pub const mkdir: u16 = 10; // request: path offset, path length            reply: status
    pub const set_permissions: u16 = 11; // request: path offset, path length, mask      reply: status
    pub const attach: u16 = 12; // request: capacity, buffer Region              reply: status
    pub const info: u16 = 13; // request: buffer offset                         reply: status

    pub const kind_file: u64 = 1;
    pub const kind_directory: u64 = 2;

    // open flags
    pub const open_create: u64 = 1; // create the file if it does not exist
    pub const open_truncate: u64 = 2; // drop existing contents

    // permissions mask bits (set_permissions / Stat.permissions)
    pub const permission_write: u64 = 1;

    /// What `stat` writes into the session buffer.
    pub const Stat = extern struct {

        kind: u32,
        permissions: u32,

        length: u64,

        created_ns: u64,
        modified_ns: u64,

    };

    /// One record in a `list` reply: a packed run of these fills the session buffer.
    pub const Entry = extern struct {

        inode: u32,

        kind: u8,
        name_len: u8,
        reserved: [2]u8,

        length: u64,

        name: [48]u8,

    };

    pub const Info = extern struct {

        sector_size: u64,
        sectors_per_block: u64,
        block_size: u64,
        block_count: u64,

        used_blocks: u64,
        free_blocks: u64,
        inode_count: u64,
        reserved: u64,

    };

};

// Display interface (07-userspace-ddd.md Section 10.6), spoken by the virtio-gpu display driver. The compositor is
// its one client: it maps the scanout Region once and pushes damage rectangles through `flush`. `attach_events`
// extends the table so a host-side window resize (a mode change) can wake the compositor through a Notification;
// the cursor methods expose the device's hardware cursor plane, so pointer motion never forces a recomposite.

pub const display = struct {

    pub const interface_id: u32 = 0x4449_5350; // "DISP"
    pub const version: u32 = 1;

    pub const mode_info: u16 = 1; // request: -                                  reply: (width<<32)|height, stride bytes, pixel format
    pub const map_framebuffer: u16 = 2; // request: -                                  reply: byte length, scanout Region in handle 0
    pub const flush: u16 = 3; // request: (x<<32)|y, (w<<32)|h                reply: status
    pub const attach_events: u16 = 4; // request: bits, Notification in handle 0      reply: status
    pub const set_cursor: u16 = 5; // request: (hot_x<<32)|hot_y, image Region in handle 0   reply: status
    pub const move_cursor: u16 = 6; // request: (x<<32)|y                           reply: status

    // The one pixel format v1 serves: 32-bit little-endian XRGB (blue in the low byte).
    pub const format_xrgb: u64 = 1;

    // The Notification bit `attach_events` signals when the display mode changes.
    pub const mode_bit: u64 = 1;

    // Cursor images are fixed 64x64 ARGB (the virtio-gpu cursor plane size).
    pub const cursor_size: usize = 64;

};

// Window interface (07-userspace-ddd.md Section 10.7), spoken by the compositor. A client renders into the surface
// Region `create` returns and `present`s a damage rectangle; the compositor blits visible windows into the
// framebuffer. `attach_events` extends the table with a per-client event ring (a shared Region of
// `events.Event` records plus a Notification), carrying input routed to the client's windows and window
// lifecycle events; `resize` extends it so fullscreen clients can follow display mode changes.

pub const window = struct {

    pub const interface_id: u32 = 0x574e_4457; // "WNDW"
    pub const version: u32 = 1;

    pub const create: u16 = 1; // request: (w<<32)|h, flags, title in words 3-5   reply: window id, (w<<32)|h, stride bytes, surface Region in handle 0
    pub const present: u16 = 2; // request: window id, (x<<32)|y, (w<<32)|h        reply: status
    pub const set_title: u16 = 3; // request: window id, title in words 3-5          reply: status
    pub const destroy: u16 = 4; // request: window id                              reply: status
    pub const attach_events: u16 = 5; // request: ring capacity in events, ring Region in handle 0, Notification in handle 1   reply: status
    pub const resize: u16 = 6; // request: window id, (w<<32)|h                   reply: (w<<32)|h, stride bytes, surface Region in handle 0

    pub const flag_undecorated: u64 = 1; // no title bar or border
    pub const flag_fullscreen: u64 = 2; // sized to the screen, tracks mode changes

    // Titles ride inline in message words 3-5, NUL-padded.
    pub const max_title: usize = 24;

    // The Notification bit the compositor signals when it pushes into a client's event ring.
    pub const ring_bit: u64 = 1;

};

// Input interface (07-userspace-ddd.md Section 10.8), spoken by the input server. Events are delivered through a
// shared event ring plus a Notification, so the client blocks in its endpoint receive rather than polling; the
// docs' `next_event`/`set_focus` numbers stay reserved for pull-mode clients. Pointer positions are normalized
// to `pointer_range` on both axes; the compositor scales them to the live mode.

pub const input = struct {

    pub const interface_id: u32 = 0x494e_5054; // "INPT"
    pub const version: u32 = 1;

    pub const next_event: u16 = 1; // reserved (05-server-protocol.md: methods are append-only)
    pub const set_focus: u16 = 2; // reserved
    pub const attach: u16 = 3; // request: ring capacity in events, notify bits (0 = ring_bit), ring Region in handle 0, Notification in handle 1   reply: status

    pub const ring_bit: u64 = 1;

    pub const pointer_range: u64 = 65535;

};

// The process-supervision (death) convention (07-userspace-ddd.md Section 10.4): a child's runtime `send`s a one-way
// death message here on exit; the spawner (Flint) receives these to reap and restart. The sender's badge
// identifies the child; data[1] carries its exit status.

pub const supervisor = struct {

    pub const death: u16 = 1; // request: exit status        (one-way; no reply)

};
