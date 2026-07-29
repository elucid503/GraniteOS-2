// Radio: internet radio over ICY/Shoutcast with in-OS MP3 decoding.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const mp3 = lib.mp3;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

// TLS needs a freestanding entropy source; https station URLs go through it.
pub const std_options = lib.rng.std_options;

pub const app_meta = .{
    .title = "Radio",
    .description = "Stream internet radio stations.",
    .icon = "radio",
    .category = "Media",
};

comptime {

    _ = lib.start;

}

// Layout.

const toolbar_h: i32 = 46;
const transport_h: i32 = 72;
const row_h: i32 = 54;
const pad: i32 = 12;
const min_list_w: i32 = 250;
const card_w_share = 45;

// Workers.

const page_size = 4096;

const network_stack_pages = 64;
const browse_stack_pages = 16;
const decode_stack_pages = 8;

// Roughly two seconds at 128 kbit/s, with about a second banked before playback starts.
const ring_capacity = 32 * 1024;
const prebuffer_bytes = 16 * 1024;

const directory_capacity = 24 * 1024;
const max_stations = 12;
const max_name = 56;
const max_genre = 44;
const max_url = lib.icy.max_url;

// Playback states, published by the workers and rendered by the UI.

const state_idle: u32 = 0;
const state_connecting: u32 = 1;
const state_buffering: u32 = 2;
const state_playing: u32 = 3;
const state_failed: u32 = 4;

const fail_none: u32 = 0;
const fail_connect: u32 = 1;
const fail_codec: u32 = 2;
const fail_audio: u32 = 3;
const fail_dropped: u32 = 4;

const tab_featured: usize = 0;
const tab_browse: usize = 1;
const tab_favourites: usize = 2;

const id_tab_base: u32 = 1;
const id_search_field: u32 = 10;
const id_search_go: u32 = 11;
const id_transport: u32 = 20;
const id_row_base: u32 = 100;
const id_star_base: u32 = 200;

const favourites_name = "radio";

const Station = struct {

    name: [max_name]u8 = undefined,
    name_len: usize = 0,

    genre: [max_genre]u8 = undefined,
    genre_len: usize = 0,

    url: [max_url]u8 = undefined,
    url_len: usize = 0,

    bitrate: u32 = 0,

    fn set(self: *Station, name: []const u8, genre: []const u8, url: []const u8, bitrate: u32) void {

        self.name_len = copy_into(&self.name, name);
        self.genre_len = copy_into(&self.genre, genre);
        self.url_len = copy_into(&self.url, url);
        self.bitrate = bitrate;

    }

    fn title(self: *const Station) []const u8 {

        return self.name[0..self.name_len];

    }

    fn subtitle(self: *const Station) []const u8 {

        return self.genre[0..self.genre_len];

    }

    fn address(self: *const Station) []const u8 {

        return self.url[0..self.url_len];

    }

};

const StationList = struct {

    items: [max_stations]Station = undefined,
    count: usize = 0,

    fn clear(self: *StationList) void {

        self.count = 0;

    }

    fn push(self: *StationList, name: []const u8, genre: []const u8, url: []const u8, bitrate: u32) void {

        if (self.count >= self.items.len or url.len == 0 or url.len > max_url) return;

        self.items[self.count].set(name, genre, url, bitrate);
        self.count += 1;

    }

};

fn copy_into(out: []u8, text: []const u8) usize {

    const length = @min(text.len, out.len);

    @memcpy(out[0..length], text[0..length]);

    return length;

}

// Curated defaults: every one of these is a plain MP3 ICY stream.

const Featured = struct {

    name: []const u8,
    genre: []const u8,
    url: []const u8,
    bitrate: u32,

};

const featured_stations = [_]Featured{

    .{ .name = "Groove Salad", .genre = "Ambient chill · SomaFM", .url = "http://ice1.somafm.com/groovesalad-128-mp3", .bitrate = 128 },
    .{ .name = "Drone Zone", .genre = "Atmospheric space · SomaFM", .url = "http://ice1.somafm.com/dronezone-128-mp3", .bitrate = 128 },
    .{ .name = "Secret Agent", .genre = "Downtempo lounge · SomaFM", .url = "http://ice1.somafm.com/secretagent-128-mp3", .bitrate = 128 },
    .{ .name = "Lush", .genre = "Vocal electronica · SomaFM", .url = "http://ice1.somafm.com/lush-128-mp3", .bitrate = 128 },
    .{ .name = "Indie Pop Rocks", .genre = "Indie · SomaFM", .url = "http://ice1.somafm.com/indiepop-128-mp3", .bitrate = 128 },
    .{ .name = "Radio Paradise", .genre = "Eclectic rock · DJ mixed", .url = "http://stream.radioparadise.com/mp3-128", .bitrate = 128 },
    .{ .name = "KEXP 90.3", .genre = "Where the music matters · Seattle", .url = "http://live-mp3-128.kexp.org/kexp128.mp3", .bitrate = 128 },
    .{ .name = "WFMU", .genre = "Freeform · New Jersey", .url = "http://stream0.wfmu.org/freeform-128k", .bitrate = 128 },
    .{ .name = "France Info", .genre = "News · France", .url = "http://icecast.radiofrance.fr/franceinfo-midfi.mp3", .bitrate = 128 },

};

// A seqlock so the UI can hand a string to a worker without either side blocking.

const Shared = struct {

    seq: u32 = 0,
    bytes: [max_url]u8 = undefined,
    len: usize = 0,

    fn publish(self: *Shared, text: []const u8) void {

        _ = @atomicRmw(u32, &self.seq, .Add, 1, .acq_rel);

        self.len = copy_into(&self.bytes, text);

        _ = @atomicRmw(u32, &self.seq, .Add, 1, .acq_rel);

    }

    fn read(self: *Shared, out: []u8) usize {

        var attempts: usize = 0;

        while (attempts < 64) : (attempts += 1) {

            const before = @atomicLoad(u32, &self.seq, .acquire);

            if (before & 1 != 0) {

                lib.time.sleep_ms(1);
                continue;

            }

            const length = @min(self.len, out.len);

            @memcpy(out[0..length], self.bytes[0..length]);

            if (@atomicLoad(u32, &self.seq, .acquire) == before) return length;

        }

        return 0;

    }

};

// Shared state.

var font: lib.draw.text.Face = undefined;
var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var featured_list: StationList = .{};
var browse_list: StationList = .{};
var browse_staging: StationList = .{};
var favourites: StationList = .{};

var active_tab: usize = tab_featured;
var selected: [3]usize = .{ 0, 0, 0 };
var scroll: i32 = 0;
var regions = ui.HitRegions{};

var search_storage: [64]u8 = undefined;
var search_buffer: ui.EditBuffer = undefined;
var search_focused = false;
var caret_on = true;
var keyboard = lib.keymap.Keyboard{};

var volume_slider: ui.Slider = .{ .value = 700 };
var volume_gain: u32 = 179;

var playing_station: Station = .{};
var playing_valid: u32 = 0;

var play_request: Shared = .{};
var play_generation: u32 = 0;
var want_play: u32 = 0;

var playback_state: u32 = state_idle;
var failure: u32 = fail_none;

var stream_rate: u32 = 0;
var stream_channels: u32 = 0;
var stream_bitrate: u32 = 0;

var title_storage: [lib.icy.max_title]u8 = undefined;
var title_len: usize = 0;
var title_seq: u32 = 0;


var browse_query: Shared = .{};
var browse_serial: u32 = 0;
var browse_done: u32 = 0;
var browse_busy: u32 = 0;
var browse_failed: u32 = 0;

var ui_wake: u32 = 0;
var running: u32 = 1;

// Producer writes `ring_write`, consumer writes `ring_read`; both are free-running byte counts.
var ring: [ring_capacity]u8 = undefined;
var ring_write: usize = 0;
var ring_read: usize = 0;

var stream: lib.icy.Stream = .{};
var decoder: lib.mp3.Decoder = undefined;
var directory: [directory_capacity]u8 = undefined;

pub fn main(args: []const []const u8) u8 {

    run(args) catch return 1;

    return 0;

}

fn run(args: []const []const u8) !void {

    lib.prefs.refresh();

    if (args.len > 0) lib.wm.bind_program(args[0]);

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try lib.wm.open_main(&connection, 860, 600, "Radio");

    _ = lib.draw.round.masks_for(8);

    search_buffer = ui.EditBuffer.init(&search_storage);

    load_featured();
    load_favourites();
    apply_volume();

    decoder = lib.mp3.Decoder.init();

    try start_worker(&network_worker, network_stack_pages);
    try start_worker(&decode_worker, decode_stack_pages);
    try start_worker(&browse_worker, browse_stack_pages);

    paint();

    var blink: u64 = lib.time.now_ms();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &want_play, 0, .release);
                    @atomicStore(u32, &running, 0, .release);

                    lib.wm.close_main(&connection, &window);

                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    clamp_scroll();

                    dirty = true;

                },

                events.kind_button_down => {

                    if (event.code == events.button_left and click(event.x, event.y)) dirty = true;

                },

                events.kind_button_up => {

                    if (event.code == events.button_left) volume_slider.release();

                },

                events.kind_pointer_move => {

                    if (volume_slider.dragging) {

                        if (volume_slider.drag(volume_rect(), event.x)) {

                            apply_volume();
                            dirty = true;

                        }

                    }

                    if (regions.pointer_move(event.x, event.y)) dirty = true;

                    update_cursor(event.x, event.y);

                },

                events.kind_scroll => {

                    if (wheel(event.value)) dirty = true;

                },

                events.kind_key_down => {

                    if (key_down(event.code)) dirty = true;

                },

                events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &ui_wake, .Xchg, 0, .acquire) != 0) dirty = true;

        if (@atomicRmw(u32, &browse_done, .Xchg, 0, .acquire) != 0) {

            browse_list = browse_staging;

            if (selected[tab_browse] >= browse_list.count) selected[tab_browse] = 0;

            scroll = 0;
            dirty = true;

        }

        const now = lib.time.now_ms();

        if (search_focused and now -% blink >= 500) {

            blink = now;
            caret_on = !caret_on;
            dirty = true;

        }

        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &ui_wake, .acquire) != 0) continue;

        // Only the caret needs a timer; otherwise park until an event or a worker wakes us.
        if (search_focused) lib.time.sleep_ms(60) else _ = sys.wait(ready) catch {};

    }

}

// Station sources.

fn load_featured() void {

    featured_list.clear();

    for (featured_stations) |entry| {

        featured_list.push(entry.name, entry.genre, entry.url, entry.bitrate);

    }

}

fn current_list() *StationList {

    return switch (active_tab) {

        tab_browse => &browse_list,
        tab_favourites => &favourites,

        else => &featured_list,

    };

}

fn selected_index() usize {

    return selected[active_tab];

}

// Favourites live in /cfgs/radio.config so they survive a reboot.

fn load_favourites() void {

    favourites.clear();

    var storage: [4096]u8 = undefined;
    const text = lib.config.load(favourites_name, &storage) catch return;

    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {

        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, '\t');

        const name = parts.next() orelse continue;
        const url = parts.next() orelse continue;
        const genre = parts.next() orelse "";

        favourites.push(name, genre, url, 0);

    }

}

fn save_favourites() void {

    var storage: [4096]u8 = undefined;
    var stream_writer = std.io.fixedBufferStream(&storage);
    const writer = stream_writer.writer();

    for (favourites.items[0..favourites.count]) |*station| {

        writer.print("{s}\t{s}\t{s}\n", .{ station.title(), station.address(), station.subtitle() }) catch break;

    }

    lib.config.save(favourites_name, stream_writer.getWritten()) catch {};

}

fn favourite_index(station: *const Station) ?usize {

    for (favourites.items[0..favourites.count], 0..) |*entry, index| {

        if (std.mem.eql(u8, entry.address(), station.address())) return index;

    }

    return null;

}

fn toggle_favourite(station: *const Station) void {

    if (favourite_index(station)) |index| {

        var cursor = index;

        while (cursor + 1 < favourites.count) : (cursor += 1) {

            favourites.items[cursor] = favourites.items[cursor + 1];

        }

        favourites.count -= 1;

    } else {

        favourites.push(station.title(), station.subtitle(), station.address(), station.bitrate);

    }

    if (selected[tab_favourites] >= favourites.count) selected[tab_favourites] = 0;

    save_favourites();

}

// Transport.

fn play_station(station: *const Station) void {

    playing_station = station.*;

    @atomicStore(u32, &playing_valid, 1, .release);
    @atomicStore(u32, &want_play, 0, .release);

    play_request.publish(station.address());

    set_title("");

    @atomicStore(u32, &failure, fail_none, .release);
    @atomicStore(u32, &stream_rate, 0, .release);
    @atomicStore(u32, &stream_channels, 0, .release);
    @atomicStore(u32, &stream_bitrate, 0, .release);
    @atomicStore(u32, &playback_state, state_connecting, .release);

    _ = @atomicRmw(u32, &play_generation, .Add, 1, .acq_rel);

    @atomicStore(u32, &want_play, 1, .release);

}

fn stop_playback() void {

    @atomicStore(u32, &want_play, 0, .release);

    _ = @atomicRmw(u32, &play_generation, .Add, 1, .acq_rel);

    @atomicStore(u32, &playback_state, state_idle, .release);

}

fn toggle_playback() void {

    if (@atomicLoad(u32, &want_play, .acquire) != 0) {

        stop_playback();
        return;

    }

    const list = current_list();

    if (list.count == 0) return;

    play_station(&list.items[@min(selected_index(), list.count - 1)]);

}

fn apply_volume() void {

    const gain = @divTrunc(volume_slider.value * @as(i32, lib.audio.gain_unity), volume_slider.span);

    @atomicStore(u32, &volume_gain, @intCast(gain), .release);

}

fn set_title(text: []const u8) void {

    _ = @atomicRmw(u32, &title_seq, .Add, 1, .acq_rel);

    title_len = copy_into(&title_storage, text);

    _ = @atomicRmw(u32, &title_seq, .Add, 1, .acq_rel);

}

fn read_title(out: []u8) usize {

    var attempts: usize = 0;

    while (attempts < 32) : (attempts += 1) {

        const before = @atomicLoad(u32, &title_seq, .acquire);

        if (before & 1 != 0) continue;

        const length = @min(title_len, out.len);

        @memcpy(out[0..length], title_storage[0..length]);

        if (@atomicLoad(u32, &title_seq, .acquire) == before) return length;

    }

    return 0;

}

fn wake_ui() void {

    @atomicStore(u32, &ui_wake, 1, .release);

    sys.notify(ready, lib.proto.window.ring_bit) catch {};

}

// Ring buffer, one producer and one consumer.

fn ring_used() usize {

    return @atomicLoad(usize, &ring_write, .acquire) -% @atomicLoad(usize, &ring_read, .acquire);

}

fn ring_free() usize {

    return ring_capacity - ring_used();

}

fn ring_reset() void {

    const write = @atomicLoad(usize, &ring_write, .acquire);

    @atomicStore(usize, &ring_read, write, .release);

}

fn ring_push(bytes: []const u8) void {

    var cursor: usize = 0;
    var write = @atomicLoad(usize, &ring_write, .acquire);

    while (cursor < bytes.len) {

        const offset = write % ring_capacity;
        const span = @min(bytes.len - cursor, ring_capacity - offset);

        @memcpy(ring[offset..][0..span], bytes[cursor..][0..span]);

        cursor += span;
        write +%= span;

    }

    @atomicStore(usize, &ring_write, write, .release);

}

fn ring_pop(out: []u8) usize {

    const available = @min(out.len, ring_used());

    var cursor: usize = 0;
    var read = @atomicLoad(usize, &ring_read, .acquire);

    while (cursor < available) {

        const offset = read % ring_capacity;
        const span = @min(available - cursor, ring_capacity - offset);

        @memcpy(out[cursor..][0..span], ring[offset..][0..span]);

        cursor += span;
        read +%= span;

    }

    @atomicStore(usize, &ring_read, read, .release);

    return available;

}

// Workers.

fn start_worker(entry: *const fn () callconv(.c) noreturn, pages: usize) !void {

    const stack = try sys.create(.region, pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(entry), base + pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn network_worker() callconv(.c) noreturn {

    var heap = lib.mem.Heap.init(cap.memory);
    var chunk: [4096]u8 = undefined;

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        if (@atomicLoad(u32, &want_play, .acquire) == 0) {

            lib.time.sleep_ms(30);
            continue;

        }

        const generation = @atomicLoad(u32, &play_generation, .acquire);

        var address: [max_url]u8 = undefined;
        const length = play_request.read(&address);

        if (length == 0) {

            lib.time.sleep_ms(30);
            continue;

        }

        ring_reset();

        @atomicStore(u32, &playback_state, state_connecting, .release);
        wake_ui();

        lib.icy.Stream.open(&stream, cap.memory, &heap, address[0..length]) catch {

            fail_stream(fail_connect, generation);
            continue;

        };

            @atomicStore(u32, &stream_bitrate, stream.bitrate, .release);

        if (stream.codec == .aac or stream.codec == .ogg) {

            stream.close();
            fail_stream(fail_codec, generation);

            continue;

        }

        @atomicStore(u32, &playback_state, state_buffering, .release);
        wake_ui();

        var serial = stream.title_serial;

        while (still_current(generation)) {

            if (ring_free() < chunk.len) {

                lib.time.sleep_ms(10);
                continue;

            }

            const count = stream.read(&chunk) catch break;

            if (count == 0) break;

            ring_push(chunk[0..count]);

            if (stream.title_serial != serial) {

                serial = stream.title_serial;

                set_title(stream.title());
                wake_ui();

            }

        }

        stream.close();

        if (still_current(generation)) fail_stream(fail_dropped, generation);

    }

    lib.start.exit();

}

fn still_current(generation: u32) bool {

    return @atomicLoad(u32, &want_play, .acquire) != 0 and
        @atomicLoad(u32, &play_generation, .acquire) == generation and
        @atomicLoad(u32, &running, .acquire) != 0;

}

fn fail_stream(reason: u32, generation: u32) void {

    if (!still_current(generation)) return;

    @atomicStore(u32, &want_play, 0, .release);
    @atomicStore(u32, &failure, reason, .release);
    @atomicStore(u32, &playback_state, state_failed, .release);

    wake_ui();

}

var decode_scratch: [4 * 1024]u8 = undefined;
var decode_pcm: [mp3.frame_samples * 2]i16 = undefined;

fn decode_worker() callconv(.c) noreturn {

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        const state = @atomicLoad(u32, &playback_state, .acquire);

        if (state != state_buffering and state != state_playing) {

            lib.time.sleep_ms(30);
            continue;

        }

        if (ring_used() < prebuffer_bytes) {

            lib.time.sleep_ms(20);
            continue;

        }

        const generation = @atomicLoad(u32, &play_generation, .acquire);

        decoder.reset();
        play_stream(generation);

    }

    lib.start.exit();

}

fn play_stream(generation: u32) void {

    var audio = lib.audio.Client.connect(cap.memory) catch {

        fail_stream(fail_audio, generation);
        return;

    };
    defer audio.deinit();

    var configured_rate: u32 = 0;
    var configured_channels: u16 = 0;

    var length: usize = 0;
    var synced = false;
    var starved: u32 = 0;

    while (still_current(generation)) {

        // Top up the linear window the decoder reads from.
        if (length < decode_scratch.len) {

            length += ring_pop(decode_scratch[length..]);

        }

        if (length < mp3.max_frame_size) {

            starved += 1;

            if (starved > 200) {

                @atomicStore(u32, &playback_state, state_buffering, .release);
                wake_ui();

                return;

            }

            lib.time.sleep_ms(5);
            continue;

        }

        starved = 0;

        if (!synced) {

            const at = mp3.find_header(decode_scratch[0..length]) orelse {

                // Nothing usable: keep the tail in case a header straddles the boundary.
                length = keep_tail(&decode_scratch, length, mp3.max_frame_size);
                continue;

            };

            length = shift_left(&decode_scratch, length, at);
            synced = true;

        }

        const result = decoder.decode(decode_scratch[0..length], &decode_pcm) catch |problem| switch (problem) {

            error.NeedMoreData => continue,

            error.Unsupported => {

                @atomicStore(u32, &failure, fail_codec, .release);
                @atomicStore(u32, &playback_state, state_failed, .release);
                @atomicStore(u32, &want_play, 0, .release);

                wake_ui();

                return;

            },

            else => {

                // Lost the frame: resync from the next byte.
                length = shift_left(&decode_scratch, length, 1);
                synced = false;

                continue;

            },

        };

        length = shift_left(&decode_scratch, length, result.consumed);

        if (result.samples == 0) continue;

        if (result.sample_rate != configured_rate or result.channels != configured_channels) {

            audio.configure(result.sample_rate, result.channels) catch {

                fail_stream(fail_audio, generation);
                return;

            };

            configured_rate = result.sample_rate;
            configured_channels = result.channels;

            @atomicStore(u32, &stream_rate, result.sample_rate, .release);
            @atomicStore(u32, &stream_channels, result.channels, .release);

            wake_ui();

        }

        apply_gain(decode_pcm[0..result.samples]);

        const bytes = std.mem.sliceAsBytes(decode_pcm[0..result.samples]);
        var written: usize = 0;

        while (written < bytes.len) {

            const count = audio.write(bytes[written..]) catch {

                fail_stream(fail_audio, generation);
                return;

            };

            if (count == 0) break;

            written += count;

        }

        // Nothing on screen changes per frame, so the UI only needs waking on a state change.
        if (@atomicLoad(u32, &playback_state, .acquire) != state_playing) {

            @atomicStore(u32, &playback_state, state_playing, .release);
            wake_ui();

        }

    }

}

fn keep_tail(buffer: []u8, length: usize, keep: usize) usize {

    if (length <= keep) return length;

    return shift_left(buffer, length, length - keep);

}

fn shift_left(buffer: []u8, length: usize, amount: usize) usize {

    const step = @min(amount, length);
    const remaining = length - step;

    std.mem.copyForwards(u8, buffer[0..remaining], buffer[step..length]);

    return remaining;

}

fn apply_gain(samples: []i16) void {

    const gain = @atomicLoad(u32, &volume_gain, .acquire);

    if (gain == lib.audio.gain_unity) return;

    for (samples) |*sample| {

        const scaled = @divTrunc(@as(i32, sample.*) * @as(i32, @intCast(gain)), lib.audio.gain_unity);

        sample.* = @intCast(std.math.clamp(scaled, -32768, 32767));

    }

}

fn browse_worker() callconv(.c) noreturn {

    var heap = lib.mem.Heap.init(cap.memory);
    var handled: u32 = 0;

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        const serial = @atomicLoad(u32, &browse_serial, .acquire);

        if (serial == handled) {

            lib.time.sleep_ms(50);
            continue;

        }

        handled = serial;

        @atomicStore(u32, &browse_busy, 1, .release);
        @atomicStore(u32, &browse_failed, 0, .release);

        wake_ui();

        var query: [max_url]u8 = undefined;
        const query_len = browse_query.read(&query);

        if (fetch_directory(&heap, query[0..query_len])) {

            @atomicStore(u32, &browse_failed, 0, .release);

        } else {

            browse_staging.clear();

            @atomicStore(u32, &browse_failed, 1, .release);

        }

        @atomicStore(u32, &browse_busy, 0, .release);
        @atomicStore(u32, &browse_done, 1, .release);

        wake_ui();

    }

    lib.start.exit();

}

const directory_host = "all.api.radio-browser.info";

fn fetch_directory(heap: *lib.mem.Heap, query: []const u8) bool {

    var path: [512]u8 = undefined;
    var path_stream = std.io.fixedBufferStream(&path);
    const writer = path_stream.writer();

    writer.writeAll("/json/stations/search?limit=12&hidebroken=true&codec=MP3&order=clickcount&reverse=true&name=") catch return false;

    for (query) |byte| {

        if (is_unreserved(byte)) {

            writer.writeByte(byte) catch return false;

        } else {

            writer.print("%{X:0>2}", .{byte}) catch return false;

        }

    }

    var url: [640]u8 = undefined;
    const target = std.fmt.bufPrint(&url, "http://{s}{s}", .{ directory_host, path_stream.getWritten() }) catch return false;

    const response = lib.http.request(cap.memory, heap, .{

        .url = target,

        .headers = &.{

            .{ .name = "User-Agent", .value = "GraniteOS-Radio/1.0" },

        },

    }, &directory) catch return false;

    if (response.status != 200) return false;

    parse_directory(response.body);

    return true;

}

fn is_unreserved(byte: u8) bool {

    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '-' or byte == '_' or byte == '.' or byte == '~';

}

/// Pull the handful of fields we show out of the directory's JSON array.
fn parse_directory(body: []const u8) void {

    browse_staging.clear();

    var cursor: usize = 0;

    while (cursor < body.len and browse_staging.count < max_stations) {

        const open = std.mem.indexOfScalarPos(u8, body, cursor, '{') orelse break;
        const close = lib.json.object_end(body, open) orelse break;
        const object = body[open .. close + 1];

        cursor = close + 1;

        var name_buffer: [max_name]u8 = undefined;
        var url_buffer: [max_url]u8 = undefined;
        var genre_buffer: [max_genre]u8 = undefined;
        var country_buffer: [max_genre]u8 = undefined;

        const name = lib.json.string(object, "name", &name_buffer) orelse continue;
        const address = lib.json.string(object, "url_resolved", &url_buffer) orelse
            lib.json.string(object, "url", &url_buffer) orelse continue;

        const tags = lib.json.string(object, "tags", &genre_buffer) orelse "";
        const country = lib.json.string(object, "country", &country_buffer) orelse "";
        const bitrate = lib.json.uint(object, "bitrate") orelse 0;

        var subtitle: [max_genre]u8 = undefined;
        const described = describe(&subtitle, tags, country);

        browse_staging.push(name, described, address, bitrate);

    }

}

fn describe(out: []u8, tags: []const u8, country: []const u8) []const u8 {

    const first_tag = if (std.mem.indexOfScalar(u8, tags, ',')) |at| tags[0..at] else tags;

    if (first_tag.len == 0) return country;
    if (country.len == 0) return first_tag;

    return std.fmt.bufPrint(out, "{s} · {s}", .{ first_tag, country }) catch first_tag;

}

// Input.

fn click(x: i32, y: i32) bool {

    if (volume_slider.press(volume_rect(), x, y)) {

        apply_volume();
        return true;

    }

    const id = regions.hit(x, y);

    if (id >= id_tab_base and id < id_tab_base + 3) {

        active_tab = id - id_tab_base;
        scroll = 0;
        search_focused = active_tab == tab_browse and search_buffer.len == 0;

        if (active_tab == tab_browse and browse_list.count == 0 and @atomicLoad(u32, &browse_busy, .acquire) == 0) {

            start_search();

        }

        return true;

    }

    if (id == id_search_field) {

        search_focused = true;
        caret_on = true;

        _ = position_caret(x);

        return true;

    }

    if (id == id_search_go) {

        start_search();
        return true;

    }

    if (id == id_transport) {

        toggle_playback();
        return true;

    }

    if (id >= id_star_base) {

        const list = current_list();
        const index = id - id_star_base;

        if (index < list.count) {

            toggle_favourite(&list.items[index]);
            return true;

        }

        return false;

    }

    if (id >= id_row_base) {

        const list = current_list();
        const index = id - id_row_base;

        if (index < list.count) {

            search_focused = false;
            selected[active_tab] = index;

            play_station(&list.items[index]);

            return true;

        }

        return false;

    }

    search_focused = false;

    return true;

}

fn key_down(code: u16) bool {

    if (keyboard.modifier(events.kind_key_down, code)) return false;

    var scratch: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &scratch);

    if (bytes.len == 0) return false;

    if (bytes.len == 1 and (bytes[0] == '\r' or bytes[0] == '\n')) {

        if (search_focused) start_search() else toggle_playback();

        return true;

    }

    if (!search_focused) {

        if (bytes.len == 1 and bytes[0] == ' ') {

            toggle_playback();
            return true;

        }

        return false;

    }

    caret_on = true;

    return search_buffer.feed(bytes, keyboard.shift);

}

fn start_search() void {

    active_tab = tab_browse;

    browse_query.publish(search_buffer.slice());

    _ = @atomicRmw(u32, &browse_serial, .Add, 1, .acq_rel);

}

fn position_caret(x: i32) bool {

    const rect = search_rect();
    const inner = rect.w - 2 * ui.field_pad;
    const index = ui.field_click_index(&font, search_buffer.slice(), 13, search_buffer.cursor, inner, x - rect.x - ui.field_pad);

    return search_buffer.set_cursor(index, false);

}

fn wheel(delta: i64) bool {

    const before = scroll;

    scroll = @intCast(scroll_model().wheel(delta, row_h));

    return scroll != before;

}

fn clamp_scroll() void {

    scroll = scroll_model().clamped();

}

fn scroll_model() ui.Scroll {

    const list = current_list();

    return .{

        .offset = scroll,
        .content = @intCast(@as(i32, @intCast(list.count)) * row_h + pad),
        .viewport = list_rect().h,

    };

}

fn update_cursor(x: i32, y: i32) void {

    if (search_rect().contains(x, y)) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (regions.hit(x, y) != 0) lib.cursor.set(&connection, .clicker) else lib.cursor.set(&connection, .pointer);

}

// Layout.

fn win_w() i32 {

    return @intCast(window.surface.width);

}

fn win_h() i32 {

    return @intCast(window.surface.height);

}

fn tab_rect(index: usize) Rect {

    const width: i32 = 104;

    return .{ .x = pad + @as(i32, @intCast(index)) * (width + 4), .y = 8, .w = width, .h = 30 };

}

fn search_rect() Rect {

    const right = win_w() - pad;
    const button: i32 = 74;
    const width = @min(240, @max(120, right - pad - 340));

    return .{ .x = right - button - 6 - width, .y = 8, .w = width, .h = 30 };

}

fn search_button_rect() Rect {

    const field = search_rect();

    return .{ .x = field.x + field.w + 6, .y = field.y, .w = 74, .h = 30 };

}

fn content_rect() Rect {

    return .{ .x = 0, .y = toolbar_h, .w = win_w(), .h = win_h() - toolbar_h - transport_h };

}

fn list_rect() Rect {

    const content = content_rect();
    const card = @divTrunc(content.w * card_w_share, 100);
    const width = @max(min_list_w, content.w - card);

    return .{ .x = content.x, .y = content.y, .w = @min(width, content.w), .h = content.h };

}

fn card_rect() Rect {

    const content = content_rect();
    const list = list_rect();

    return .{ .x = list.x + list.w, .y = content.y, .w = content.w - list.w, .h = content.h };

}

fn row_rect(index: usize) Rect {

    const list = list_rect();

    return .{

        .x = list.x + pad,
        .y = list.y + pad + @as(i32, @intCast(index)) * row_h - scroll,

        .w = list.w - pad * 2 - ui.scrollbar_width,
        .h = row_h - 4,

    };

}

fn transport_rect() Rect {

    return .{ .x = 0, .y = win_h() - transport_h, .w = win_w(), .h = transport_h };

}

fn play_button_rect() Rect {

    const bar = transport_rect();

    return .{ .x = pad + 4, .y = bar.y + 12, .w = 48, .h = 48 };

}

fn volume_rect() Rect {

    const bar = transport_rect();
    const width: i32 = @min(160, @max(80, win_w() - 480));

    return .{ .x = win_w() - pad - 44 - width, .y = bar.y + 28, .w = width, .h = 16 };

}

fn scrollbar_rect() Rect {

    const list = list_rect();

    return .{ .x = list.x + list.w - ui.scrollbar_width - 2, .y = list.y + 2, .w = ui.scrollbar_width, .h = list.h - 4 };

}

// Painting.

fn paint() void {

    const surface = &window.surface;

    surface.fill(ui.theme.window_bg);
    regions.reset();

    paint_toolbar(surface);
    paint_list(surface);
    paint_card(surface);
    paint_transport(surface);

    gfx.fence();
    window.present_all() catch {};

}

fn paint_toolbar(surface: *const gfx.Surface) void {

    const bar = Rect{ .x = 0, .y = 0, .w = win_w(), .h = toolbar_h };

    surface.fill_rect(bar, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = toolbar_h - 1, .w = bar.w, .h = 1 }, ui.theme.border);

    const labels = [_][]const u8{ "Featured", "Browse", "Favourites" };

    for (labels, 0..) |label, index| {

        const rect = tab_rect(index);
        const id = id_tab_base + @as(u32, @intCast(index));

        regions.add(id, rect);

        ui.widgets.button(surface, &font, rect, label, .{

            .hovered = regions.hovered(id),
            .selected = active_tab == index,
            .outlined = true,

        }, .{ .size = 13, .idle = ui.theme.surface });

    }

    const field = search_rect();

    regions.add(id_search_field, field);

    ui.paint_text_field(surface, &font, field, &search_buffer, "Search stations", search_focused, search_focused and caret_on, 13);

    const go = search_button_rect();

    regions.add(id_search_go, go);

    const busy = @atomicLoad(u32, &browse_busy, .acquire) != 0;

    ui.widgets.button(surface, &font, go, if (busy) "..." else "Search", .{

        .hovered = regions.hovered(id_search_go),
        .accent = true,

    }, .{ .size = 13 });

}

fn paint_list(surface: *const gfx.Surface) void {

    const list = list_rect();
    const clipped = surface.clipped(list);
    const items = current_list();

    surface.fill_rect(.{ .x = list.x + list.w - 1, .y = list.y, .w = 1, .h = list.h }, ui.theme.border);

    if (items.count == 0) {

        const message = empty_message();

        text_center(surface, list, 13, message, ui.theme.text_faint);

        return;

    }

    const playing = @atomicLoad(u32, &playing_valid, .acquire) != 0;

    for (items.items[0..items.count], 0..) |*station, index| {

        const rect = row_rect(index);

        if (rect.y + rect.h < list.y or rect.y > list.y + list.h) continue;

        const id = id_row_base + @as(u32, @intCast(index));

        regions.add(id, rect);

        const active = playing and std.mem.eql(u8, station.address(), playing_station.address());
        const chosen = index == selected_index();

        if (active) {

            ui.fill_round_rect(&clipped, rect, 7, ui.theme.accent_dim);

        } else if (regions.hovered(id)) {

            ui.fill_round_rect(&clipped, rect, 7, ui.theme.hover);

        } else if (chosen) {

            ui.fill_round_rect(&clipped, rect, 7, ui.theme.surface);

        }

        const icon_side: i32 = 18;
        const icon = Rect{ .x = rect.x + 12, .y = rect.y + @divTrunc(rect.h - icon_side, 2), .w = icon_side, .h = icon_side };

        lib.draw.vector.icon_in(&clipped, icon, if (active) lib.icons.waves else lib.icons.radio, if (active) ui.theme.text else ui.theme.text_dim);

        const star = Rect{ .x = rect.x + rect.w - 34, .y = rect.y + @divTrunc(rect.h - 20, 2), .w = 20, .h = 20 };
        const star_id = id_star_base + @as(u32, @intCast(index));

        regions.add(star_id, star);

        const favourite = favourite_index(station) != null;
        const star_tint = if (favourite) ui.theme.accent else if (regions.hovered(star_id)) ui.theme.text_dim else ui.theme.text_faint;

        lib.draw.vector.icon_in(&clipped, star, lib.icons.star, star_tint);

        const text_x = icon.x + icon_side + 12;
        const text_w = star.x - 10 - text_x;

        font.draw(&clipped, text_x, rect.y + 8, 14, ui.truncate(&font, station.title(), 14, text_w), ui.theme.text);

        var detail_buffer: [80]u8 = undefined;
        const detail = if (station.bitrate > 0)
            std.fmt.bufPrint(&detail_buffer, "{s} · {d} kbps", .{ station.subtitle(), station.bitrate }) catch station.subtitle()
        else
            station.subtitle();

        font.draw(&clipped, text_x, rect.y + 28, 11, ui.truncate(&font, detail, 11, text_w), ui.theme.text_dim);

    }

    const model = scroll_model();

    if (model.overflowing()) ui.scrollbar(surface, scrollbar_rect(), model);

}

fn empty_message() []const u8 {

    return switch (active_tab) {

        tab_browse => if (@atomicLoad(u32, &browse_busy, .acquire) != 0) "Searching the station directory..."
        else if (@atomicLoad(u32, &browse_failed, .acquire) != 0) "Directory unavailable. Check the network and try again."
        else "Type a name or genre, then press Search.",

        tab_favourites => "No favourites yet. Tap a star to keep a station here.",

        else => "No stations.",

    };

}

/// Now playing, laid out like a music player: cover tile, track, artist, then the station itself.
fn paint_card(surface: *const gfx.Surface) void {

    const card = card_rect();

    if (card.w < 180) return;

    const clipped = surface.clipped(card);
    const inner = card.inset(pad + 6);
    const playing = @atomicLoad(u32, &playing_valid, .acquire) != 0;
    const state = @atomicLoad(u32, &playback_state, .acquire);

    // A short window drops the cover tile rather than squashing it.
    const side = @min(@min(168, inner.w - 40), @divTrunc(inner.h * 2, 5));

    var cursor = inner.y + 8;

    if (side >= 64) {

        const art = Rect{ .x = inner.x + @divTrunc(inner.w - side, 2), .y = cursor, .w = side, .h = side };

        ui.fill_round_rect(&clipped, art, 12, ui.theme.surface);
        ui.stroke_round_rect(&clipped, art, 12, 1, ui.theme.border);

        const glyph = @divTrunc(side * 2, 5);

        lib.draw.vector.icon_in(&clipped, .{

            .x = art.x + @divTrunc(side - glyph, 2),
            .y = art.y + @divTrunc(side - glyph, 2),

            .w = glyph,
            .h = glyph,

        }, lib.icons.radio, if (state == state_playing) ui.theme.accent else ui.theme.text_faint);

        cursor += side + 26;

    }

    if (!playing) {

        text_center(&clipped, .{ .x = inner.x, .y = cursor, .w = inner.w, .h = 20 }, 14, "Nothing playing", ui.theme.text_dim);
        text_center(&clipped, .{ .x = inner.x, .y = cursor + 24, .w = inner.w, .h = 18 }, 12, "Pick a station to start listening", ui.theme.text_faint);

        return;

    }

    var title_text: [lib.icy.max_title]u8 = undefined;
    const length = read_title(&title_text);
    const now = split_track(title_text[0..length]);

    // The track is the headline; the station name drops to a caption below it.
    const headline = if (now.track.len > 0) now.track else playing_station.title();

    cursor += paint_wrapped(&clipped, .{ .x = inner.x, .y = cursor, .w = inner.w, .h = 60 }, 19, headline, ui.theme.text);

    const caption = if (now.artist.len > 0) now.artist else playing_station.subtitle();

    if (caption.len > 0) {

        text_center(&clipped, .{ .x = inner.x, .y = cursor + 2, .w = inner.w, .h = 20 }, 14, caption, ui.theme.text_dim);

        cursor += 24;

    }

    cursor += 18;

    clipped.fill_rect(.{ .x = inner.x + @divTrunc(inner.w, 4), .y = cursor, .w = @divTrunc(inner.w, 2), .h = 1 }, ui.theme.border);

    cursor += 18;

    // Once the track has the headline, the station belongs here with the format details.
    if (now.track.len > 0) {

        text_center(&clipped, .{ .x = inner.x, .y = cursor, .w = inner.w, .h = 18 }, 13, playing_station.title(), ui.theme.text_dim);

        cursor += 20;

    }

    var status_buffer: [96]u8 = undefined;

    text_center(&clipped, .{ .x = inner.x, .y = cursor, .w = inner.w, .h = 18 }, 11, status_line(&status_buffer, state), status_tint(state));

}

const Track = struct {

    track: []const u8,
    artist: []const u8,

};

/// ICY stream titles are conventionally "Artist - Track"; show the track first, as a player would.
fn split_track(text: []const u8) Track {

    const trimmed = std.mem.trim(u8, text, " ");

    if (std.mem.indexOf(u8, trimmed, " - ")) |at| {

        return .{ .track = trimmed[at + 3 ..], .artist = trimmed[0..at] };

    }

    return .{ .track = trimmed, .artist = "" };

}

fn status_line(buffer: []u8, state: u32) []const u8 {

    return switch (state) {

        state_connecting => "Connecting...",
        state_buffering => "Buffering...",

        state_playing => blk: {

            const rate = @atomicLoad(u32, &stream_rate, .acquire);
            const channels = @atomicLoad(u32, &stream_channels, .acquire);
            const bitrate = @atomicLoad(u32, &stream_bitrate, .acquire);

            break :blk std.fmt.bufPrint(buffer, "Playing · MP3 {d} kbps · {d}.{d} kHz {s}", .{

                bitrate,
                rate / 1000,
                (rate % 1000) / 100,
                if (channels == 1) "mono" else "stereo",

            }) catch "Playing";

        },

        state_failed => switch (@atomicLoad(u32, &failure, .acquire)) {

            fail_codec => "This station is not MP3 — unsupported format.",
            fail_audio => "Audio device unavailable.",
            fail_dropped => "Stream ended. Press play to reconnect.",

            else => "Could not reach this station.",

        },

        else => "Stopped",

    };

}

fn status_tint(state: u32) gfx.Color {

    return if (state == state_failed) ui.theme.warn else ui.theme.text_dim;

}

/// Draws `text` centred over at most two lines, returning the height consumed.
fn paint_wrapped(surface: *const gfx.Surface, rect: Rect, size: u32, text: []const u8, color: gfx.Color) i32 {

    const line_height = font.line_height(size) + 4;
    var remaining = text;
    var y = rect.y;
    var lines: i32 = 0;

    while (remaining.len > 0 and lines < 2) : (lines += 1) {

        var take = ui.truncate(&font, remaining, size, rect.w).len;

        if (take == 0) break;

        // Break on a space when the line is full and more text follows.
        if (take < remaining.len and lines == 0) {

            if (std.mem.lastIndexOfScalar(u8, remaining[0..take], ' ')) |space| {

                if (space > take / 2) take = space;

            }

        }

        text_center(surface, .{ .x = rect.x, .y = y, .w = rect.w, .h = line_height }, size, remaining[0..take], color);

        y += line_height;
        remaining = std.mem.trimLeft(u8, remaining[take..], " ");

    }

    return @max(line_height, y - rect.y);

}

fn paint_transport(surface: *const gfx.Surface) void {

    const bar = transport_rect();

    surface.fill_rect(bar, ui.theme.surface);
    surface.fill_rect(.{ .x = 0, .y = bar.y, .w = bar.w, .h = 1 }, ui.theme.border);

    const button = play_button_rect();

    regions.add(id_transport, button);

    const active = @atomicLoad(u32, &want_play, .acquire) != 0;
    const fill = if (regions.hovered(id_transport)) ui.theme.active else ui.theme.accent_dim;

    ui.fill_round_rect(surface, button, @divTrunc(button.w, 2), fill);

    const glyph_side: i32 = 20;

    // The play triangle sits better a shade right of centre; the stop square is symmetric.
    const nudge: i32 = if (active) 0 else 1;

    const glyph = Rect{

        .x = button.x + @divTrunc(button.w - glyph_side, 2) + nudge,
        .y = button.y + @divTrunc(button.h - glyph_side, 2),

        .w = glyph_side,
        .h = glyph_side,

    };

    lib.draw.vector.icon_in(surface, glyph, if (active) lib.icons.stop else lib.icons.play, ui.theme.text);

    const text_x = button.x + button.w + 16;
    const volume = volume_rect();
    const text_w = volume.x - 24 - text_x;

    if (text_w > 40) {

        const clipped = surface.clipped(.{ .x = text_x, .y = bar.y, .w = text_w, .h = bar.h });

        if (@atomicLoad(u32, &playing_valid, .acquire) != 0) {

            var title_text: [lib.icy.max_title]u8 = undefined;
            const length = read_title(&title_text);
            const now = split_track(title_text[0..length]);

            // Same ordering as the card: track first, station underneath.
            const primary = if (now.track.len > 0) now.track else playing_station.title();
            const secondary = if (now.track.len > 0) playing_station.title() else playing_station.subtitle();

            font.draw(&clipped, text_x, bar.y + 18, 14, ui.truncate(&font, primary, 14, text_w), ui.theme.text);
            font.draw(&clipped, text_x, bar.y + 38, 12, ui.truncate(&font, secondary, 12, text_w), ui.theme.text_dim);

        } else {

            font.draw(&clipped, text_x, bar.y + 28, 13, "Nothing playing", ui.theme.text_faint);

        }

    }

    lib.draw.vector.icon_in(surface, .{ .x = volume.x - 26, .y = volume.y - 2, .w = 18, .h = 18 }, lib.icons.volume, ui.theme.text_dim);

    volume_slider.paint(surface, volume, ui.theme.accent, ui.theme.border, ui.theme.text);

    var percent_buffer: [8]u8 = undefined;
    const percent = std.fmt.bufPrint(&percent_buffer, "{d}%", .{@divTrunc(volume_slider.value * 100, volume_slider.span)}) catch "";

    font.draw(surface, volume.x + volume.w + 10, volume.y + 1, 11, percent, ui.theme.text_faint);

}

fn text_center(surface: *const gfx.Surface, rect: Rect, size: u32, value: []const u8, color: gfx.Color) void {

    const visible = ui.truncate(&font, value, size, rect.w);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, size), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(size), 2);

    font.draw(surface, x, y, size, visible, color);

}

const testing = std.testing;

test "directory json yields station rows" {

    const body =
        \\[{"name":"Jazz \u00e9 Radio","url":"http://a/","url_resolved":"http://a/x.mp3","codec":"MP3","bitrate":128,"tags":"jazz,blues","country":"France"},
        \\{"name":"Second","url_resolved":"http://b/y.mp3","bitrate":64,"tags":"","country":"Spain"}]
    ;

    parse_directory(body);

    try testing.expectEqual(@as(usize, 2), browse_staging.count);
    try testing.expectEqualStrings("http://a/x.mp3", browse_staging.items[0].address());
    try testing.expectEqualStrings("jazz · France", browse_staging.items[0].subtitle());
    try testing.expectEqual(@as(u32, 128), browse_staging.items[0].bitrate);
    try testing.expectEqualStrings("Spain", browse_staging.items[1].subtitle());

}

test "ring buffer wraps without losing bytes" {

    ring_write = 0;
    ring_read = 0;

    var pattern: [1000]u8 = undefined;

    for (&pattern, 0..) |*byte, index| byte.* = @truncate(index);

    var round: usize = 0;

    while (round < ring_capacity / pattern.len + 2) : (round += 1) {

        ring_push(&pattern);

        var out: [1000]u8 = undefined;

        try testing.expectEqual(pattern.len, ring_pop(&out));
        try testing.expectEqualSlices(u8, &pattern, &out);

    }

    try testing.expectEqual(@as(usize, 0), ring_used());

}
