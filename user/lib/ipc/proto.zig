// Shared interface constants: word 0 is method in/status out; method 0 is Identify; methods are append-only.

pub const identify: u16 = 0;

// Stream interface (console, pipes, terminals): attach shares one Region; reads/writes pass offset/length only.

pub const stream = struct {

    pub const interface_id: u32 = 0x5354_524d; // "STRM"
    pub const version: u32 = 1;

    pub const read: u16 = 1; // request: offset, capacity        reply: bytes read
    pub const write: u16 = 2; // request: offset, length          reply: bytes written
    pub const set_mode: u16 = 3; // request: mode                    reply: status
    pub const attach: u16 = 4; // request: capacity, buffer Region  reply: status
    pub const detach: u16 = 5; // request: -                        reply: status

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

// Block interface (virtio-blk): attach shares a session buffer; sector I/O uses offsets into it.

pub const block = struct {

    pub const interface_id: u32 = 0x424c_4f4b; // "BLOK"
    pub const version: u32 = 2;

    pub const sector_size: usize = 512;

    pub const read_sector: u16 = 1; // request: sector, offset           reply: status
    pub const write_sector: u16 = 2; // request: sector, offset           reply: status
    pub const capacity: u16 = 3; // request: -                        reply: sector count
    pub const attach: u16 = 4; // request: capacity, buffer Region   reply: status
    pub const read_sectors: u16 = 5; // request: sector, count, offset    reply: status
    pub const write_sectors: u16 = 6; // request: sector, count, offset    reply: status

};

// Audio output interface. Clients attach one shared buffer and submit interleaved PCM frames from it.

pub const audio = struct {

    pub const interface_id: u32 = 0x4155_4449; // "AUDI"
    pub const version: u32 = 1;

    pub const configure: u16 = 1; // request: rate, channels, sample bits   reply: status
    pub const write: u16 = 2; // request: offset, byte length             reply: bytes consumed
    pub const drain: u16 = 3; // request: -                               reply: status
    pub const stop: u16 = 4; // request: -                               reply: status
    pub const attach: u16 = 5; // request: capacity, buffer Region         reply: status

    pub const format_s16_le: u64 = 16;
    pub const max_write: usize = 16 * 1024;

};

// Filesystem interface: paths, data, and results ride in one attached session buffer as (offset, length) pairs.

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
    pub const detach: u16 = 14; // request: -                                     reply: status

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

// Display interface (virtio-gpu): compositor maps scanout once, flushes damage; attach_events and cursor avoid full recomposites.

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

// Window interface (compositor): create/present surfaces; attach_events delivers input and lifecycle via an event ring.

pub const window = struct {

    pub const interface_id: u32 = 0x574e_4457; // "WNDW"
    pub const version: u32 = 1;

    pub const create: u16 = 1; // request: (w<<32)|h, flags, title in words 3-5   reply: window id, (w<<32)|h, stride bytes, surface Region in handle 0
    pub const present: u16 = 2; // request: window id, (x<<32)|y, (w<<32)|h        reply: snapshot complete
    pub const set_title: u16 = 3; // request: window id, title in words 3-5          reply: status
    pub const destroy: u16 = 4; // request: window id                              reply: status
    pub const attach_events: u16 = 5; // request: ring capacity in events, ring Region in handle 0, Notification in handle 1   reply: status
    pub const resize: u16 = 6; // request: window id, (w<<32)|h                   reply: (w<<32)|h, stride bytes, surface Region in handle 0
    pub const list: u16 = 7; // request: info Region in handle 0 (attached once)   reply: window count, records written to the info buffer
    pub const activate: u16 = 8; // request: window id                              reply: status (focus and raise, for the taskbar)
    pub const screen_info: u16 = 9; // request: -                                    reply: (width<<32)|height
    pub const move: u16 = 10; // request: window id, (x<<32)|y                     reply: status
    pub const minimize: u16 = 11; // request: window id                              reply: status
    pub const restore: u16 = 12; // request: window id                              reply: status
    pub const subscribe_list: u16 = 13; // request: info Region in handle 0, Notification in handle 1   reply: window count (and later notifications on changes)
    pub const notify_prefs: u16 = 14; // request: -                                    reply: status (broadcasts prefs_changed to every connected client)
    pub const set_cursor: u16 = 15; // request: cursor kind (0=pointer, 1=clicker, 2=selector)   reply: status
    pub const activate_title: u16 = 16; // request: title in words 1-3                    reply: status
    pub const close_title: u16 = 17; // request: title in words 1-3                       reply: status
    pub const place_relative: u16 = 18; // request: window id, anchor id, local (x<<32)|y reply: status
    pub const minimize_hint: u16 = 19; // request: window id, taskbar-local indicator center x   reply: status

    pub const flag_undecorated: u64 = 1; // no title bar or border
    pub const flag_fullscreen: u64 = 2; // sized to the screen, tracks mode changes
    pub const flag_panel: u64 = 4; // an undecorated dock pinned to the screen bottom, always above ordinary windows
    pub const flag_minimized: u64 = 8; // hidden from the desktop but still tracked by the compositor
    pub const flag_desktop: u64 = 16; // fullscreen undecorated layer pinned beneath ordinary windows, for desktop chrome
    pub const flag_maximized: u64 = 32; // fills the free area above the panel; restore geometry kept in the manager
    pub const flag_quartz: u64 = 64; // premultiplied-alpha surface with compositor backdrop effects

    // Titles ride inline in message words 3-5, NUL-padded.
    pub const max_title: usize = 24;

    // The compositor's window-table capacity, so a `list` client can size its info buffer (mirrors the manager).
    pub const max_windows: usize = 64;

    // The Notification bit the compositor signals when it pushes into a client's event ring.
    pub const ring_bit: u64 = 1;

    // The Notification bit the compositor signals when the open-window list changes.
    pub const list_bit: u64 = 2;

    /// One record the compositor writes into a `list` client's info buffer, so the taskbar can show open windows.
    pub const WindowInfo = extern struct {

        id: u32,
        flags: u32,
        focused: u32,
        minimized: u32,
        title_len: u32,

        x: i32,
        y: i32,
        width: u32,
        height: u32,

        title: [max_title]u8,

    };

};

// Launcher interface: taskbar spawns bundled programs by inline name without holding spawn authority.

pub const launch = struct {

    pub const interface_id: u32 = 0x4c4e_4348; // "LNCH"
    pub const version: u32 = 1;

    pub const max_length: usize = 32;

    pub const spawn: u16 = 1; // request: name length, name in words 1-4          reply: status

};

// Input interface: events via shared ring + Notification; pointers normalized to pointer_range for compositor scaling.

pub const input = struct {

    pub const interface_id: u32 = 0x494e_5054; // "INPT"
    pub const version: u32 = 1;

    pub const next_event: u16 = 1; // reserved (05-server-protocol.md: methods are append-only)
    pub const set_focus: u16 = 2; // reserved
    pub const attach: u16 = 3; // request: ring capacity in events, notify bits (0 = ring_bit), ring Region in handle 0, Notification in handle 1   reply: status

    pub const ring_bit: u64 = 1;

    pub const pointer_range: u64 = 65535;

};

// Supervisor death convention: child sends one-way exit message; badge identifies child, data[1] is status.

pub const supervisor = struct {

    pub const death: u16 = 1; // request: exit status        (one-way; no reply)

};

// Net driver interface: async RX into a frame ring, synchronous TX via a shared staging buffer.

pub const net = struct {

    pub const interface_id: u32 = 0x4e45_5431; // "NET1"
    pub const version: u32 = 1;

    pub const attach: u16 = 1; // request: rx ring capacity (frames), tx buffer capacity (bytes)
    // handles: [0] = rx frame Ring Region (driver writes), [1] = tx staging Region (driver reads), [2] = Notification (driver signals on new RX frames)   reply: status
    pub const mac_address: u16 = 2; // request: -                     reply: mac[0..4] as le32 in data[1], mac[4..6] in low 16 bits of data[2]
    pub const transmit: u16 = 3; // request: length (bytes staged at offset 0)   reply: status
    pub const link_status: u16 = 4; // request: -                     reply: 1 = up, 0 = down

    pub const rx_bit: u64 = 1; // the Notification bit the driver signals when it pushes into the RX frame ring

};

// Socket interface: one attached session buffer; wire is non-blocking (WouldBlock + readiness Notification); lib.net blocks.

pub const socket = struct {

    pub const interface_id: u32 = 0x534f_434b; // "SOCK"
    pub const version: u32 = 1;

    pub const attach: u16 = 1; // request: capacity                                    handles: [0] = buffer Region, [1] = readiness Notification   reply: status
    pub const open: u16 = 2; // request: kind (stream|dgram)                          reply: socket id
    pub const bind: u16 = 3; // request: sid, addr, port                              reply: status
    pub const listen: u16 = 4; // request: sid, backlog                                 reply: status
    pub const connect: u16 = 5; // request: sid, addr, port                              reply: status (accepted; wait for `connected`/`err` on poll)
    pub const accept: u16 = 6; // request: sid                                          reply: new sid (data[1]), peer addr (data[2]), peer port (data[3])   | WouldBlock
    pub const send: u16 = 7; // request: sid, offset, length                          reply: bytes queued (data[1])   | WouldBlock
    pub const recv: u16 = 8; // request: sid, offset, capacity                        reply: bytes read (data[1])     | WouldBlock
    pub const close: u16 = 9; // request: sid                                          reply: status
    pub const poll: u16 = 10; // request: sid                                          reply: readiness bitmask (data[1])
    pub const local_addr: u16 = 11; // request: sid                                          reply: addr (data[1]), port (data[2])
    pub const detach: u16 = 12; // request: -                                           reply: status (releases every socket this session owns)
    pub const resolve: u16 = 13; // request: sid-less: offset, length of hostname in session buffer   reply: addr (data[1]) | WouldBlock

    pub const kind_stream: u64 = 1;
    pub const kind_dgram: u64 = 2;

    // Readiness bits, mirroring the input/window ring-bit convention: signaled into the client's own Notification.
    pub const readable: u64 = 1;
    pub const writable: u64 = 2;
    pub const connected: u64 = 4;
    pub const closed: u64 = 8;
    pub const accept_ready: u64 = 16;
    pub const err: u64 = 32;
    pub const resolved: u64 = 64;

};

// Metrics interface: boot-time timezone and coarse geo from public IP (v1).

pub const metrics = struct {

    pub const interface_id: u32 = 0x4d45_5452; // "METR"
    pub const version: u32 = 1;

    pub const get_timezone: u16 = 1; // request: - reply: status (status_*), offset minutes (data[2], signed via bitcast), country code packed as 2 ascii bytes (data[3])
    pub const get_location: u16 = 2; // request: - reply: status (status_*), lat f64 bits (data[2]), lon f64 bits (data[3]), city in data[4..5] (16 bytes little-endian)

    pub const max_city: usize = 16;

    pub const status_pending: u64 = 0; // lookup has not completed yet
    pub const status_ready: u64 = 1; // offset/country below came from a successful lookup
    pub const status_unavailable: u64 = 2; // lookup failed; offset defaults to 0 (UTC)

};
