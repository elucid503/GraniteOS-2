// Sprout CDN: authenticated cloud file browser over HTTP/HTTPS.

const std = @import("std");

const lib = @import("lib");

const cap = lib.cap;
const events = lib.events;
const gfx = lib.gfx;
const ipc = lib.ipc;
const proto = lib.proto;
const sys = lib.sys;
const ui = lib.ui;

const Rect = gfx.Rect;

pub const std_options = lib.rng.std_options;

pub const app_meta = .{

    .title = "Sprout CDN",
    .description = "Manage files in Sprout CDN.",
    .icon = "file",
    .category = "Internet",

};

comptime {

    _ = lib.start;

}

const max_nodes = 96;
const max_folders = 16;
const response_capacity = 96 * 1024;
const endpoint_capacity = 384;
const token_capacity = 2048;
const id_capacity = 64;
const name_capacity = 128;
const path_capacity = lib.file_picker.max_path;

const toolbar_h: i32 = 48;
const account_h: i32 = 36;
const table_header_h: i32 = 28;
const table_gap_h: i32 = 8;
const row_h: i32 = 38;
const footer_h: i32 = 48;
const margin: i32 = 12;

const cdn_origin = "https://cdn.sprout.software";
const sprout_origin = "https://sprout.software";
const session_path = "/root/user/.sprout-cdn-session";

const Screen = enum {

    setup,
    files,
    shared,

};

const Focus = enum {

    email,
    password,
    prompt,

};

const Modal = enum {

    none,
    new_folder,
    rename,
    delete,

};

const PickerPurpose = enum {

    none,
    upload,
    download,

};

const Task = enum(u8) {

    none,
    connect,
    restore,
    refresh,
    create_folder,
    rename,
    delete,
    toggle_public,
    upload,
    download,

};

const Node = struct {

    id: [id_capacity]u8 = undefined,
    id_len: usize = 0,

    name: [name_capacity]u8 = undefined,
    name_len: usize = 0,

    mime: [64]u8 = undefined,
    mime_len: usize = 0,

    size: u64 = 0,
    folder: bool = false,
    public: bool = false,
    failed: bool = false,

    fn id_slice(self: *const Node) []const u8 {

        return self.id[0..self.id_len];

    }

    fn name_slice(self: *const Node) []const u8 {

        return self.name[0..self.name_len];

    }

};

const Folder = struct {

    id: [id_capacity]u8 = undefined,
    id_len: usize = 0,

    name: [name_capacity]u8 = undefined,
    name_len: usize = 0,

    fn id_slice(self: *const Folder) []const u8 {

        return self.id[0..self.id_len];

    }

    fn name_slice(self: *const Folder) []const u8 {

        return self.name[0..self.name_len];

    }

};

const WireNode = struct {

    id: []const u8,
    kind: []const u8,
    name: []const u8,

    size: u64 = 0,
    mimeType: []const u8 = "",
    public: bool = false,
    sync: []const u8 = "",

};

const WireItems = struct {

    items: []const WireNode,

};

const WireMe = struct {

    email: []const u8,
    namespaceNodeId: []const u8,
    storageUsed: u64,

};

const WireError = struct {

    message: []const u8 = "request failed",
    code: []const u8 = "",

};

const WireErrorEnvelope = struct {

    @"error": WireError = .{},

};

const SproutErrorEnvelope = struct {

    @"error": []const u8 = "Sprout sign-in failed",

};

const RedirectData = struct {

    redirectUrl: []const u8,

};

const RedirectEnvelope = struct {

    data: RedirectData,

};

const OAuthRequest = struct {

    client_id: [128]u8 = undefined,
    client_id_len: usize = 0,

    redirect_uri: [endpoint_capacity]u8 = undefined,
    redirect_uri_len: usize = 0,

    scope: [128]u8 = undefined,
    scope_len: usize = 0,

    state: [128]u8 = undefined,
    state_len: usize = 0,

    challenge: [128]u8 = undefined,
    challenge_len: usize = 0,

};

var font: lib.draw.text.Face = undefined;

var connection: lib.window.Connection = undefined;
var window: lib.window.Window = undefined;
var ready: cap.Handle = 0;

var files: ?lib.fs.Client = null;
var picker: lib.file_picker.FilePicker = undefined;
var picker_purpose: PickerPurpose = .none;

var login_email_storage: [128]u8 = undefined;
var password_storage: [256]u8 = undefined;
var prompt_storage: [name_capacity]u8 = undefined;

var login_email_field = ui.EditBuffer{ .bytes = &login_email_storage };
var password_field = ui.EditBuffer{ .bytes = &password_storage };
var prompt_field = ui.EditBuffer{ .bytes = &prompt_storage };

var focused: Focus = .email;
var keyboard = lib.keymap.Keyboard{};
var reveal_password = false;

var screen: Screen = .setup;
var modal: Modal = .none;
var selected: ?usize = null;
var scroll: usize = 0;

var nodes: [max_nodes]Node = undefined;
var node_count: usize = 0;

var folders: [max_folders]Folder = undefined;
var folder_count: usize = 0;

var email: [128]u8 = undefined;
var email_len: usize = 0;
var storage_used: u64 = 0;

var status: [192]u8 = undefined;
var status_len: usize = 0;
var status_bad = false;
var busy: u32 = 0;

var lock: ipc.Lock = .{};
var running: u32 = 1;
var worker_alive: u32 = 0;
var tick: u32 = 0;
var request_pending: u32 = 0;
var pending_task: Task = .none;

var session_token: [token_capacity]u8 = undefined;
var session_token_len: usize = 0;

var task_email: [128]u8 = undefined;
var task_email_len: usize = 0;
var task_password: [256]u8 = undefined;
var task_password_len: usize = 0;

var task_folder: [id_capacity]u8 = undefined;
var task_folder_len: usize = 0;
var task_id: [id_capacity]u8 = undefined;
var task_id_len: usize = 0;
var task_name: [name_capacity]u8 = undefined;
var task_name_len: usize = 0;
var task_path: [path_capacity]u8 = undefined;
var task_path_len: usize = 0;
var task_public = false;
var task_shared = false;

var response_buffer: [response_capacity]u8 = undefined;
var body_buffer: [2048]u8 = undefined;

pub fn main(_: []const []const u8) u8 {

    run() catch return 1;

    return 0;

}

fn run() !void {

    lib.prefs.refresh();

    var bundle = try lib.desktop.open_bundle();
    font = try lib.desktop.ui_font(&bundle);

    connection = try lib.desktop.connect(cap.memory);
    ready = connection.ready;
    window = try connection.create_window(820, 560, 0, "Sprout CDN");

    picker.init();
    files = lib.fs.Client.connect(cap.memory) catch null;

    set_status("Sign in with your Sprout Account.", false);

    try start_worker();

    if (load_session()) begin_task(.restore);

    paint();

    while (true) {

        var dirty = false;

        while (connection.poll_event()) |event| {

            if (picker.open) {

                dirty = handle_picker_event(event) or dirty;
                continue;

            }

            switch (event.kind) {

                events.kind_window_close => {

                    @atomicStore(u32, &running, 0, .release);

                    // Let the worker finish or exit so netstack/FS sessions detach cleanly.
                    var waits: usize = 0;

                    while (@atomicLoad(u32, &worker_alive, .acquire) != 0 and waits < 500) : (waits += 1) {

                        lib.time.sleep_ms(10);

                    }

                    if (files) |*client| client.close();

                    window.destroy();
                    return;

                },

                events.kind_window_resize => {

                    window.resize(@intCast(event.x), @intCast(event.y)) catch {};
                    clamp_scroll();
                    dirty = true;

                },

                events.kind_key_down => dirty = key_down(event.code) or dirty,
                events.kind_key_up => _ = keyboard.modifier(events.kind_key_up, event.code),

                events.kind_button_down => {

                    if (event.code == events.button_left) dirty = click(event.x, event.y) or dirty;

                },

                events.kind_pointer_move => {

                    update_cursor(event.x, event.y);

                },

                events.kind_scroll => dirty = wheel(event.value) or dirty,

                events.kind_prefs_changed => {

                    _ = lib.prefs.apply_event(event);
                    dirty = true;

                },

                else => {},

            }

        }

        if (@atomicRmw(u32, &tick, .Xchg, 0, .acquire) != 0) {

            clamp_scroll();
            dirty = true;

        }

        if (take_picker_result()) dirty = true;
        if (dirty) paint();

        if (connection.poll_event() != null or @atomicLoad(u32, &tick, .acquire) != 0) continue;

        _ = sys.wait(ready) catch {};

    }

}

fn set_field(field: *ui.EditBuffer, text: []const u8) void {

    const length = @min(field.bytes.len, text.len);

    @memcpy(field.bytes[0..length], text[0..length]);
    field.len = length;
    field.cursor = length;
    field.anchor = length;

}

fn handle_picker_event(event: events.Event) bool {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return switch (event.kind) {

        events.kind_button_down => if (event.code == events.button_left) picker.click(event.x, event.y, width, height) else false,
        events.kind_pointer_move => picker.pointer_move(event.x, event.y, width, height),
        events.kind_scroll => picker.scroll_by(event.value, width, height),
        events.kind_key_down => picker.key(event.code),
        events.kind_key_up => blk: {

            picker.key_up(event.code);
            break :blk false;

        },
        events.kind_window_resize => blk: {

            window.resize(@intCast(event.x), @intCast(event.y)) catch {};
            break :blk true;

        },
        else => false,

    };

}

fn take_picker_result() bool {

    const result = picker.take_result() orelse return false;

    switch (picker_purpose) {

        .upload => queue_path_task(.upload, result),
        .download => queue_path_task(.download, result),
        .none => {},

    }

    picker_purpose = .none;

    return true;

}

fn key_down(code: u16) bool {

    if (keyboard.modifier(events.kind_key_down, code)) return false;

    var scratch: [3]u8 = undefined;
    const bytes = keyboard.bytes(code, &scratch);

    if (bytes.len == 0) return false;

    if (bytes.len == 1 and bytes[0] == 27) {

        if (modal != .none) {

            modal = .none;
            return true;

        }

        return false;

    }

    if (bytes.len == 1 and (bytes[0] == '\r' or bytes[0] == '\n')) {

        if (modal != .none) {

            confirm_modal();
            return true;

        }

        if (screen == .setup) {

            connect_account();
            return true;

        }

        if (selected_node()) |node| {

            if (node.folder and screen == .files) enter_folder(node);

        }

        return true;

    }

    const field: *ui.EditBuffer = switch (focused) {

        .email => &login_email_field,
        .password => &password_field,
        .prompt => &prompt_field,

    };

    return field.feed(bytes, keyboard.shift);

}

fn click(x: i32, y: i32) bool {

    if (modal != .none) return click_modal(x, y);
    if (screen == .setup) return click_setup(x, y);

    if (back_rect().contains(x, y)) {

        if (screen == .shared) {

            screen = .files;
            queue_refresh();

        } else if (folder_count > 1 and !busy_now()) {

            folder_count -= 1;
            selected = null;
            scroll = 0;
            queue_refresh();

        }

        return true;

    }

    if (refresh_rect().contains(x, y)) {

        queue_refresh();
        return true;

    }

    if (account_rect().contains(x, y)) {

        disconnect_account();
        return true;

    }

    if (shared_rect().contains(x, y)) {

        if (!busy_now()) {

            screen = if (screen == .shared) .files else .shared;
            selected = null;
            scroll = 0;
            queue_refresh();

        }

        return true;

    }

    if (screen == .files and new_folder_rect().contains(x, y)) {

        open_prompt(.new_folder, "");
        return true;

    }

    if (screen == .files and upload_rect().contains(x, y)) {

        show_upload_picker();
        return true;

    }

    const row = row_at(x, y);

    if (row) |index| {

        selected = index;
        return true;

    }

    if (busy_now()) return false;

    if (selected_node()) |node| {

        if (primary_rect().contains(x, y)) {

            if (node.folder and screen == .files) enter_folder(node) else show_download_picker(node);

            return true;

        }

        if (screen == .files and rename_rect().contains(x, y)) {

            open_prompt(.rename, node.name_slice());
            return true;

        }

        if (screen == .files and public_rect().contains(x, y)) {

            queue_node_task(.toggle_public, node, !node.public);
            return true;

        }

        if (screen == .files and delete_rect().contains(x, y)) {

            modal = .delete;
            return true;

        }

    }

    return false;

}

fn click_setup(x: i32, y: i32) bool {

    if (login_email_rect().contains(x, y)) {

        focused = .email;
        position_field(&login_email_field, login_email_rect(), x);
        return true;

    }

    if (password_rect().contains(x, y)) {

        focused = .password;
        position_field(&password_field, password_rect(), x);
        return true;

    }

    if (reveal_rect().contains(x, y)) {

        reveal_password = !reveal_password;
        return true;

    }

    if (connect_rect().contains(x, y)) {

        connect_account();
        return true;

    }

    return false;

}

fn click_modal(x: i32, y: i32) bool {

    const frame = modal_rect();

    if (modal != .delete and prompt_rect().contains(x, y)) {

        focused = .prompt;
        position_field(&prompt_field, prompt_rect(), x);
        return true;

    }

    if (modal_cancel_rect().contains(x, y) or !frame.contains(x, y)) {

        modal = .none;
        return true;

    }

    if (modal_confirm_rect().contains(x, y)) {

        confirm_modal();
        return true;

    }

    return false;

}

fn confirm_modal() void {

    switch (modal) {

        .new_folder => {

            const name = std.mem.trim(u8, prompt_field.slice(), " \t\r\n");

            if (name.len == 0) {

                set_status("Folder name cannot be empty.", true);
                return;

            }

            queue_name_task(.create_folder, name);

        },

        .rename => {

            const node = selected_node() orelse return;
            const name = std.mem.trim(u8, prompt_field.slice(), " \t\r\n");

            if (name.len == 0) {

                set_status("Name cannot be empty.", true);
                return;

            }

            queue_node_name_task(.rename, node, name);

        },

        .delete => {

            const node = selected_node() orelse return;

            queue_node_task(.delete, node, false);

        },

        .none => return,

    }

    modal = .none;

}

fn position_field(field: *ui.EditBuffer, rect: Rect, x: i32) void {

    const inner_w = rect.w - 2 * ui.field_pad;
    const rel_x = x - rect.x - ui.field_pad;
    const index = ui.field_click_index(&font, field.slice(), 13, field.cursor, inner_w, rel_x);

    _ = field.set_cursor(index, keyboard.shift);

}

fn wheel(delta: i64) bool {

    if (screen == .setup or modal != .none) return false;

    const before = scroll;
    const visible = visible_rows();
    const maximum = if (node_count > visible) node_count - visible else 0;

    if (delta < 0) {

        scroll -|= 2;

    } else {

        scroll = @min(maximum, scroll + 2);

    }

    return scroll != before;

}

fn clamp_scroll() void {

    const visible = visible_rows();
    const maximum = if (node_count > visible) node_count - visible else 0;

    scroll = @min(scroll, maximum);

    if (selected) |index| {

        if (index >= node_count) selected = null;

    }

}

fn selected_node() ?*const Node {

    const index = selected orelse return null;

    if (index >= node_count) return null;

    return &nodes[index];

}

fn enter_folder(node: *const Node) void {

    if (busy_now() or !node.folder or folder_count >= folders.len) return;

    set_folder(&folders[folder_count], node.id_slice(), node.name_slice());
    folder_count += 1;
    selected = null;
    scroll = 0;

    queue_refresh();

}

fn connect_account() void {

    if (busy_now()) return;

    const login_email = std.mem.trim(u8, login_email_field.slice(), " \t\r\n");
    const password = password_field.slice();

    if (login_email.len == 0 or password.len == 0) {

        set_status("Email and password are required.", true);
        return;

    }

    task_email_len = copy_text(&task_email, login_email);
    task_password_len = copy_text(&task_password, password);
    @memset(&password_storage, 0);
    set_field(&password_field, "");

    begin_task(.connect);

}

fn disconnect_account() void {

    if (busy_now()) return;

    clear_session();

    @memset(&session_token, 0);
    session_token_len = 0;
    @memset(&password_storage, 0);
    set_field(&password_field, "");

    node_count = 0;
    folder_count = 0;
    selected = null;
    scroll = 0;
    screen = .setup;
    focused = .password;

    set_status("Sign in with your Sprout Account.", false);

}

fn load_session() bool {

    const client: *lib.fs.Client = if (files) |*handle| handle else return false;
    const file = client.open_path(session_path, 0) catch return false;
    defer client.close_file(file) catch {};

    const length = client.read(file, 0, &session_token) catch return false;
    const token = std.mem.trim(u8, session_token[0..length], " \t\r\n");

    if (token.len == 0) return false;

    if (token.ptr != session_token[0..].ptr) std.mem.copyForwards(u8, session_token[0..token.len], token);

    session_token_len = token.len;

    return true;

}

fn save_session() void {

    var client = lib.fs.Client.connect(cap.memory) catch return;
    defer client.close();

    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = client.open_path(session_path, flags) catch return;
    defer client.close_file(file) catch {};

    _ = client.write(file, 0, session_token[0..session_token_len]) catch return;

}

fn clear_session() void {

    var client = lib.fs.Client.connect(cap.memory) catch return;
    defer client.close();

    client.delete(session_path) catch {};

}

fn normalize_token(text: []const u8) []const u8 {

    var token = std.mem.trim(u8, text, " \t\r\n");

    if (std.mem.indexOf(u8, token, "#auth=")) |at| {

        token = token[at + "#auth=".len ..];

    } else if (std.mem.startsWith(u8, token, "auth=")) {

        token = token["auth=".len..];

    }

    if (std.mem.indexOfScalar(u8, token, '&')) |at| token = token[0..at];

    return token;

}

fn queue_refresh() void {

    if (busy_now() or folder_count == 0) return;

    task_folder_len = copy_text(&task_folder, folders[folder_count - 1].id_slice());
    task_shared = screen == .shared;

    begin_task(.refresh);

}

fn queue_name_task(kind: Task, name: []const u8) void {

    if (busy_now() or folder_count == 0) return;

    task_folder_len = copy_text(&task_folder, folders[folder_count - 1].id_slice());
    task_name_len = copy_text(&task_name, name);
    task_shared = false;

    begin_task(kind);

}

fn queue_node_name_task(kind: Task, node: *const Node, name: []const u8) void {

    if (busy_now() or folder_count == 0) return;

    task_folder_len = copy_text(&task_folder, folders[folder_count - 1].id_slice());
    task_id_len = copy_text(&task_id, node.id_slice());
    task_name_len = copy_text(&task_name, name);
    task_shared = false;

    begin_task(kind);

}

fn queue_node_task(kind: Task, node: *const Node, value: bool) void {

    if (busy_now() or folder_count == 0) return;

    task_folder_len = copy_text(&task_folder, folders[folder_count - 1].id_slice());
    task_id_len = copy_text(&task_id, node.id_slice());
    task_name_len = copy_text(&task_name, node.name_slice());
    task_public = value;
    task_shared = screen == .shared;

    begin_task(kind);

}

fn queue_path_task(kind: Task, path: []const u8) void {

    const node = selected_node();

    if (busy_now() or folder_count == 0) return;

    task_folder_len = copy_text(&task_folder, folders[folder_count - 1].id_slice());
    task_path_len = copy_text(&task_path, path);
    task_shared = screen == .shared;

    if (kind == .download) {

        const selected_item = node orelse return;

        task_id_len = copy_text(&task_id, selected_item.id_slice());
        task_name_len = copy_text(&task_name, selected_item.name_slice());

    }

    begin_task(kind);

}

fn begin_task(kind: Task) void {

    @atomicStore(u32, &busy, 1, .release);
    pending_task = kind;
    set_status(task_label(kind), false);

    @atomicStore(u32, &request_pending, 1, .release);
    notify_ui();

}

fn task_label(kind: Task) []const u8 {

    return switch (kind) {

        .connect => "Signing in to Sprout...",
        .restore => "Restoring Sprout CDN session...",
        .refresh => "Refreshing...",
        .create_folder => "Creating folder...",
        .rename => "Renaming...",
        .delete => "Deleting...",
        .toggle_public => "Updating visibility...",
        .upload => "Uploading file...",
        .download => "Downloading file...",
        .none => "",

    };

}

fn open_prompt(kind: Modal, value: []const u8) void {

    if (busy_now()) return;

    modal = kind;
    focused = .prompt;
    set_field(&prompt_field, value);

}

fn show_upload_picker() void {

    if (busy_now()) return;

    if (files) |*client| {

        picker_purpose = .upload;
        picker.show_open(client, &font, .all, "/");

    } else {

        set_status("The local filesystem is unavailable.", true);

    }

}

fn show_download_picker(node: *const Node) void {

    if (busy_now() or node.folder) return;

    if (files) |*client| {

        selected = selected orelse return;
        picker_purpose = .download;
        picker.show_save(client, &font, .all, "/", node.name_slice());

    } else {

        set_status("The local filesystem is unavailable.", true);

    }

}

fn start_worker() !void {

    const stack_pages = 64;
    const page_size = 4096;
    const stack = try sys.create(.region, stack_pages * page_size, cap.memory);
    const base = try sys.map(cap.self_space, stack, 0, sys.read | sys.write);
    const thread = try sys.create_thread(@intFromPtr(&worker), base + stack_pages * page_size);

    sys.close(stack) catch {};

    try sys.start(thread);

}

fn worker() callconv(.c) noreturn {

    @atomicStore(u32, &worker_alive, 1, .release);

    var heap = lib.mem.Heap.init(cap.memory);

    while (@atomicLoad(u32, &running, .acquire) != 0) {

        if (@atomicRmw(u32, &request_pending, .Xchg, 0, .acquire) == 0) {

            lib.time.sleep_ms(10);
            continue;

        }

        if (@atomicLoad(u32, &running, .acquire) == 0) break;

        const task = pending_task;

        do_task(&heap, task) catch |failure| {

            if (failure != error.RequestRejected) finish_error(@errorName(failure));

        };

    }

    @atomicStore(u32, &worker_alive, 0, .release);
    lib.start.exit();

}

fn do_task(heap: *lib.mem.Heap, task: Task) !void {

    switch (task) {

        .connect => try worker_connect(heap),
        .restore => try worker_resume(heap),
        .refresh => try worker_load_view(heap),
        .create_folder => try worker_create_folder(heap),
        .rename => try worker_rename(heap),
        .delete => try worker_delete(heap),
        .toggle_public => try worker_toggle_public(heap),
        .upload => try worker_upload(heap),
        .download => try worker_download(heap),
        .none => return,

    }

}

fn worker_connect(heap: *lib.mem.Heap) !void {

    defer {

        @memset(&task_password, 0);
        task_password_len = 0;
        @memset(&body_buffer, 0);

    }

    var body_len: usize = 0;

    try append_text(&body_buffer, &body_len, "{\"email\":");
    try append_json_string(&body_buffer, &body_len, task_email[0..task_email_len]);
    try append_text(&body_buffer, &body_len, ",\"password\":");
    try append_json_string(&body_buffer, &body_len, task_password[0..task_password_len]);
    try append_text(&body_buffer, &body_len, "}");

    const json_header = [_]lib.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
    const login_response = try direct_request(
        heap,
        "POST",
        sprout_origin ++ "/api/auth/login",
        &json_header,
        body_buffer[0..body_len],
    );

    try expect_sprout_status(heap, login_response, 200);

    var sprout_session: [token_capacity]u8 = undefined;
    defer @memset(&sprout_session, 0);

    const sprout_session_len = find_cookie(login_response.headers, "sprout_session", &sprout_session) orelse {

        finish_error("Sprout did not return a login session.");
        return error.RequestRejected;

    };

    @memset(&response_buffer, 0);
    @memset(&body_buffer, 0);

    worker_progress("Authorizing Sprout CDN...");

    const login_redirect = try direct_request(
        heap,
        "GET",
        cdn_origin ++ "/api/v1/auth/login",
        &.{},
        "",
    );

    const authorize_url = try redirect_location(login_redirect, sprout_origin);

    if (std.mem.indexOf(u8, authorize_url, "#auth_error=") != null) {

        finish_error("Sprout CDN could not start sign-in.");
        return error.RequestRejected;

    }

    var oauth_request = try parse_oauth_request(authorize_url);
    var authorization_storage: [token_capacity + 8]u8 = undefined;
    defer @memset(&authorization_storage, 0);

    const authorization = try std.fmt.bufPrint(
        &authorization_storage,
        "Bearer {s}",
        .{sprout_session[0..sprout_session_len]},
    );
    const authorize_headers = [_]lib.http.Header{

        .{ .name = "Authorization", .value = authorization },
        .{ .name = "Content-Type", .value = "application/json" },

    };

    body_len = 0;

    try append_text(&body_buffer, &body_len, "{\"clientId\":");
    try append_json_string(&body_buffer, &body_len, oauth_request.client_id[0..oauth_request.client_id_len]);
    try append_text(&body_buffer, &body_len, ",\"redirectUri\":");
    try append_json_string(&body_buffer, &body_len, oauth_request.redirect_uri[0..oauth_request.redirect_uri_len]);
    try append_text(&body_buffer, &body_len, ",\"scope\":");
    try append_json_string(&body_buffer, &body_len, oauth_request.scope[0..oauth_request.scope_len]);
    try append_text(&body_buffer, &body_len, ",\"state\":");
    try append_json_string(&body_buffer, &body_len, oauth_request.state[0..oauth_request.state_len]);
    try append_text(&body_buffer, &body_len, ",\"codeChallenge\":");
    try append_json_string(&body_buffer, &body_len, oauth_request.challenge[0..oauth_request.challenge_len]);
    try append_text(&body_buffer, &body_len, ",\"codeChallengeMethod\":\"S256\"}");

    const authorize_response = try direct_request(
        heap,
        "POST",
        sprout_origin ++ "/api/oauth/authorize",
        &authorize_headers,
        body_buffer[0..body_len],
    );

    try expect_sprout_status(heap, authorize_response, 200);

    const parsed_redirect = try std.json.parseFromSlice(RedirectEnvelope, heap.allocator(), authorize_response.body, .{

        .ignore_unknown_fields = true,

    });
    defer parsed_redirect.deinit();

    var callback_storage: [endpoint_capacity + 256]u8 = undefined;
    const callback_len = copy_text(&callback_storage, parsed_redirect.value.data.redirectUrl);
    const callback_url = callback_storage[0..callback_len];

    if (!trusted_https_url(callback_url, "cdn.sprout.software")) return error.InvalidResponse;

    const callback_response = try direct_request(heap, "GET", callback_url, &.{}, "");
    const frontend_url = try redirect_location(callback_response, cdn_origin);

    if (std.mem.indexOf(u8, frontend_url, "#auth_error=") != null) {

        finish_error("Sprout CDN could not complete sign-in.");
        return error.RequestRejected;

    }

    const encoded_token = normalize_token(frontend_url);
    var decoded_token: [token_capacity]u8 = undefined;
    defer @memset(&decoded_token, 0);

    const decoded_len = try percent_decode(encoded_token, &decoded_token);

    if (decoded_len == 0) return error.InvalidResponse;

    session_token_len = copy_text(&session_token, decoded_token[0..decoded_len]);

    @memset(std.mem.asBytes(&oauth_request), 0);
    @memset(&response_buffer, 0);

    try worker_open_account(heap);
    save_session();

}

fn worker_resume(heap: *lib.mem.Heap) !void {

    try worker_open_account(heap);

}

fn worker_open_account(heap: *lib.mem.Heap) !void {

    const response = try api_request(heap, "GET", "/api/v1/me", "");

    try expect_status(heap, response, 200);

    const parsed = try std.json.parseFromSlice(WireMe, heap.allocator(), response.body, .{

        .ignore_unknown_fields = true,

    });
    defer parsed.deinit();

    lock.acquire();

    email_len = copy_text(&email, parsed.value.email);
    storage_used = parsed.value.storageUsed;
    folder_count = 1;
    set_folder(&folders[0], parsed.value.namespaceNodeId, "My files");
    screen = .files;
    selected = null;
    scroll = 0;

    task_folder_len = copy_text(&task_folder, parsed.value.namespaceNodeId);
    task_shared = false;

    lock.release();

    try worker_load_view(heap);

}

fn worker_load_view(heap: *lib.mem.Heap) !void {

    var path: [id_capacity + 32]u8 = undefined;
    const target = if (task_shared)
        "/api/v1/shared"
    else
        try std.fmt.bufPrint(&path, "/api/v1/folders/{s}", .{task_folder[0..task_folder_len]});

    const response = try api_request(heap, "GET", target, "");

    try expect_status(heap, response, 200);
    try install_nodes(heap, response.body);

    finish_success(if (task_shared) "Shared files are up to date." else "Folder is up to date.");

}

fn worker_create_folder(heap: *lib.mem.Heap) !void {

    var length: usize = 0;

    try append_text(&body_buffer, &length, "{\"parentId\":");
    try append_json_string(&body_buffer, &length, task_folder[0..task_folder_len]);
    try append_text(&body_buffer, &length, ",\"name\":");
    try append_json_string(&body_buffer, &length, task_name[0..task_name_len]);
    try append_text(&body_buffer, &length, ",\"public\":false}");

    const response = try api_request(heap, "POST", "/api/v1/folders", body_buffer[0..length]);

    try expect_status(heap, response, 202);
    try worker_load_view(heap);

}

fn worker_rename(heap: *lib.mem.Heap) !void {

    var path: [id_capacity + 32]u8 = undefined;
    const target = try std.fmt.bufPrint(&path, "/api/v1/contents/{s}", .{task_id[0..task_id_len]});
    var length: usize = 0;

    try append_text(&body_buffer, &length, "{\"attribute\":\"name\",\"value\":");
    try append_json_string(&body_buffer, &length, task_name[0..task_name_len]);
    try append_text(&body_buffer, &length, "}");

    const response = try api_request(heap, "PATCH", target, body_buffer[0..length]);

    try expect_status(heap, response, 202);
    try worker_load_view(heap);

}

fn worker_delete(heap: *lib.mem.Heap) !void {

    var length: usize = 0;

    try append_text(&body_buffer, &length, "{\"ids\":[");
    try append_json_string(&body_buffer, &length, task_id[0..task_id_len]);
    try append_text(&body_buffer, &length, "]}");

    const response = try api_request(heap, "DELETE", "/api/v1/contents", body_buffer[0..length]);

    try expect_status(heap, response, 202);
    try worker_load_view(heap);

}

fn worker_toggle_public(heap: *lib.mem.Heap) !void {

    var path: [id_capacity + 32]u8 = undefined;
    const target = try std.fmt.bufPrint(&path, "/api/v1/contents/{s}", .{task_id[0..task_id_len]});
    const value = if (task_public) "true" else "false";
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"attribute\":\"public\",\"value\":\"{s}\"}}", .{value});
    const response = try api_request(heap, "PATCH", target, body);

    try expect_status(heap, response, 202);
    try worker_load_view(heap);

}

fn direct_request(
    heap: *lib.mem.Heap,
    method: []const u8,
    url: []const u8,
    headers: []const lib.http.Header,
    body: []const u8,
) !lib.http.Response {

    return lib.http.request(cap.memory, heap, .{

        .method = method,
        .url = url,
        .headers = headers,
        .body = body,

    }, &response_buffer);

}

fn expect_sprout_status(heap: *lib.mem.Heap, response: lib.http.Response, expected: u16) !void {

    if (response.status == expected) return;

    const parsed = std.json.parseFromSlice(SproutErrorEnvelope, heap.allocator(), response.body, .{

        .ignore_unknown_fields = true,

    }) catch {

        var fallback: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&fallback, "Sprout returned HTTP {d}.", .{response.status}) catch "Sprout sign-in failed.";

        finish_error(text);
        return error.RequestRejected;

    };
    defer parsed.deinit();

    finish_error(parsed.value.@"error");

    return error.RequestRejected;

}

fn redirect_location(response: lib.http.Response, expected_origin: []const u8) ![]const u8 {

    if (response.status != 302 and response.status != 303 and response.status != 307 and response.status != 308) {

        return error.InvalidResponse;

    }

    const location = response.header("location") orelse return error.InvalidResponse;

    if (std.mem.startsWith(u8, location, "/")) return location;

    const expected = lib.url.parse(expected_origin) orelse return error.Invalid;

    if (!trusted_https_url(location, expected.host)) return error.InvalidResponse;

    return location;

}

fn trusted_https_url(text: []const u8, host: []const u8) bool {

    const parsed = lib.url.parse(text) orelse return false;

    return lib.url.is_tls(parsed.scheme) and parsed.port == 443 and std.ascii.eqlIgnoreCase(parsed.host, host);

}

fn find_cookie(headers: []const u8, name: []const u8, out: []u8) ?usize {

    var lines = std.mem.splitSequence(u8, headers, "\r\n");

    while (lines.next()) |line| {

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");

        if (!std.ascii.eqlIgnoreCase(header_name, "set-cookie")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const pair_end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        const pair = value[0..pair_end];
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        if (!std.mem.eql(u8, std.mem.trim(u8, pair[0..equals], " \t"), name)) continue;

        const cookie = pair[equals + 1 ..];

        if (cookie.len == 0 or cookie.len > out.len) return null;

        @memcpy(out[0..cookie.len], cookie);

        return cookie.len;

    }

    return null;

}

fn parse_oauth_request(location: []const u8) !OAuthRequest {

    if (!trusted_https_url(location, "sprout.software")) return error.InvalidResponse;

    var request = OAuthRequest{};

    request.client_id_len = try query_parameter(location, "client_id", &request.client_id);
    request.redirect_uri_len = try query_parameter(location, "redirect_uri", &request.redirect_uri);
    request.scope_len = try query_parameter(location, "scope", &request.scope);
    request.state_len = try query_parameter(location, "state", &request.state);
    request.challenge_len = try query_parameter(location, "code_challenge", &request.challenge);

    var method: [16]u8 = undefined;
    const method_len = try query_parameter(location, "code_challenge_method", &method);
    var response_type: [16]u8 = undefined;
    const response_type_len = try query_parameter(location, "response_type", &response_type);

    if (!std.mem.eql(u8, method[0..method_len], "S256")) return error.InvalidResponse;
    if (!std.mem.eql(u8, response_type[0..response_type_len], "code")) return error.InvalidResponse;
    if (!valid_cdn_scopes(request.scope[0..request.scope_len])) return error.InvalidResponse;
    if (!trusted_https_url(request.redirect_uri[0..request.redirect_uri_len], "cdn.sprout.software")) return error.InvalidResponse;

    return request;

}

fn valid_cdn_scopes(scope: []const u8) bool {

    var identity = false;
    var offline = false;
    var values = std.mem.tokenizeScalar(u8, scope, ' ');

    while (values.next()) |value| {

        if (std.mem.eql(u8, value, "identity")) {

            identity = true;

        } else if (std.mem.eql(u8, value, "offline_access")) {

            offline = true;

        } else {

            return false;

        }

    }

    return identity and offline;

}

fn query_parameter(location: []const u8, name: []const u8, out: []u8) !usize {

    const query_start = std.mem.indexOfScalar(u8, location, '?') orelse return error.InvalidResponse;
    const fragment_start = std.mem.indexOfScalarPos(u8, location, query_start + 1, '#') orelse location.len;
    var pairs = std.mem.splitScalar(u8, location[query_start + 1 .. fragment_start], '&');

    while (pairs.next()) |pair| {

        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        if (!std.mem.eql(u8, pair[0..equals], name)) continue;

        return percent_decode(pair[equals + 1 ..], out);

    }

    return error.InvalidResponse;

}

fn percent_decode(text: []const u8, out: []u8) !usize {

    var source: usize = 0;
    var length: usize = 0;

    while (source < text.len) {

        if (length >= out.len) return error.NoSpaceLeft;

        if (text[source] == '%') {

            if (source + 2 >= text.len) return error.Invalid;

            const high = hex_value(text[source + 1]) orelse return error.Invalid;
            const low = hex_value(text[source + 2]) orelse return error.Invalid;

            out[length] = high * 16 + low;
            source += 3;

        } else {

            out[length] = if (text[source] == '+') ' ' else text[source];
            source += 1;

        }

        length += 1;

    }

    return length;

}

fn hex_value(byte: u8) ?u8 {

    return switch (byte) {

        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,

    };

}

fn worker_progress(text: []const u8) void {

    set_status(text, false);
    notify_ui();

}

fn api_request(heap: *lib.mem.Heap, method: []const u8, path: []const u8, body: []const u8) !lib.http.Response {

    var url_buffer: [endpoint_capacity + 256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ cdn_origin, path });
    var authorization_buffer: [token_capacity + 8]u8 = undefined;
    const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{session_token[0..session_token_len]});
    const headers = [_]lib.http.Header{

        .{ .name = "Authorization", .value = authorization },
        .{ .name = "Content-Type", .value = "application/json" },

    };

    return if (body.len == 0)
        lib.http.request(cap.memory, heap, .{

            .method = method,
            .url = url,
            .headers = headers[0..1],

        }, &response_buffer)
    else
        lib.http.request(cap.memory, heap, .{

            .method = method,
            .url = url,
            .headers = headers[0..2],
            .body = body,

        }, &response_buffer);

}

fn expect_status(heap: *lib.mem.Heap, response: lib.http.Response, expected: u16) !void {

    if (response.status == expected) return;

    if (response.status == 401) {

        expire_session();
        return error.RequestRejected;

    }

    const parsed = std.json.parseFromSlice(WireErrorEnvelope, heap.allocator(), response.body, .{

        .ignore_unknown_fields = true,

    }) catch {

        var fallback: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&fallback, "CDN returned HTTP {d}.", .{response.status}) catch "CDN request failed.";

        finish_error(text);
        return error.RequestRejected;

    };
    defer parsed.deinit();

    finish_error(parsed.value.@"error".message);

    return error.RequestRejected;

}

fn install_nodes(heap: *lib.mem.Heap, body: []const u8) !void {

    const parsed = try std.json.parseFromSlice(WireItems, heap.allocator(), body, .{

        .ignore_unknown_fields = true,

    });
    defer parsed.deinit();

    lock.acquire();

    node_count = @min(parsed.value.items.len, nodes.len);

    for (parsed.value.items[0..node_count], 0..) |wire, index| copy_node(&nodes[index], wire);

    selected = null;
    scroll = 0;

    lock.release();

}

fn worker_upload(heap: *lib.mem.Heap) !void {

    var client = try lib.fs.Client.connect(cap.memory);
    defer client.close();

    const local_path = task_path[0..task_path_len];
    const stat = try client.stat(local_path);

    if (stat.kind != proto.filesystem.kind_file) return error.Invalid;

    const file = try client.open_path(local_path, 0);
    defer client.close_file(file) catch {};

    const name = basename(local_path);
    const boundary = "----granite-sprout-7d4f9b2c";
    var multipart_head: [1024]u8 = undefined;
    var safe_name: [name_capacity]u8 = undefined;
    const filename = safe_filename(name, &safe_name);
    const prefix = try std.fmt.bufPrint(
        &multipart_head,
        "--{s}\r\nContent-Disposition: form-data; name=\"folderId\"\r\n\r\n{s}\r\n--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        .{ boundary, task_folder[0..task_folder_len], boundary, filename },
    );
    var multipart_tail: [64]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&multipart_tail, "\r\n--{s}--\r\n", .{boundary});
    const content_length = prefix.len + stat.length + suffix.len;

    var url_buffer: [endpoint_capacity + 64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/api/v1/upload", .{cdn_origin});
    const parsed_url = lib.url.parse(url) orelse return error.Invalid;
    var authorization: [token_capacity + 8]u8 = undefined;
    const auth = try std.fmt.bufPrint(&authorization, "Bearer {s}", .{session_token[0..session_token_len]});
    var content_type: [96]u8 = undefined;
    const mime = try std.fmt.bufPrint(&content_type, "multipart/form-data; boundary={s}", .{boundary});
    var request_head: [4096]u8 = undefined;
    const head = try format_request_head(&request_head, parsed_url, "POST", auth, mime, content_length);
    var connection_http: lib.http.Connection = undefined;

    try lib.http.Connection.connect_host(
        &connection_http,
        cap.memory,
        heap,
        parsed_url.host,
        parsed_url.port,
        lib.url.is_tls(parsed_url.scheme),
    );
    defer connection_http.close();

    try connection_http.send_all(head);
    try connection_http.send_all(prefix);

    var offset: u64 = 0;
    var chunk: [16 * 1024]u8 = undefined;

    while (offset < stat.length) {

        const length = try client.read(file, offset, &chunk);

        if (length == 0) return error.Truncated;

        try connection_http.send_all(chunk[0..length]);
        offset += length;

    }

    try connection_http.send_all(suffix);

    const response = try lib.http.receive_response(&connection_http, &response_buffer);

    try expect_status(heap, response, 201);
    try worker_load_view(heap);

}

fn worker_download(heap: *lib.mem.Heap) !void {

    var url_buffer: [endpoint_capacity + id_capacity + 64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "{s}/api/v1/contents/{s}/content",
        .{ cdn_origin, task_id[0..task_id_len] },
    );
    const parsed_url = lib.url.parse(url) orelse return error.Invalid;
    var authorization: [token_capacity + 8]u8 = undefined;
    const auth = try std.fmt.bufPrint(&authorization, "Bearer {s}", .{session_token[0..session_token_len]});
    var request_head: [4096]u8 = undefined;
    const head = try format_request_head(&request_head, parsed_url, "GET", auth, null, null);
    var connection_http: lib.http.Connection = undefined;

    try lib.http.Connection.connect_host(
        &connection_http,
        cap.memory,
        heap,
        parsed_url.host,
        parsed_url.port,
        lib.url.is_tls(parsed_url.scheme),
    );
    defer connection_http.close();

    try connection_http.send_all(head);

    var initial: [8192]u8 = undefined;
    var initial_len: usize = 0;
    var header_end: ?usize = null;

    while (initial_len < initial.len) {

        const length = try connection_http.recv(initial[initial_len..]);

        if (length == 0) break;

        initial_len += length;

        if (std.mem.indexOf(u8, initial[0..initial_len], "\r\n\r\n")) |at| {

            header_end = at + 4;
            break;

        }

    }

    const body_start = header_end orelse return error.InvalidResponse;
    const response = try lib.http.parse_response(initial[0..initial_len]);
    const expected: ?u64 = if (response.content_length()) |length| @intCast(length) else null;

    if (response.status != 200 and response.status != 206) {

        try expect_status(heap, response, 200);

    }

    var client = try lib.fs.Client.connect(cap.memory);
    defer client.close();

    const flags = proto.filesystem.open_create | proto.filesystem.open_truncate;
    const file = try client.open_path(task_path[0..task_path_len], flags);
    defer client.close_file(file) catch {};

    var offset: u64 = 0;

    if (initial_len > body_start) {

        const body = initial[body_start..initial_len];

        if (expected) |length| {

            if (@as(u64, @intCast(body.len)) > length) return error.InvalidResponse;

        }

        const written = try client.write(file, offset, body);

        if (written != body.len) return error.WriteFailed;

        offset += written;

    }

    // Match FS payload_capacity: fill from the socket before each write to cut IPC round-trips.
    var chunk: [lib.fs.payload_capacity]u8 = undefined;

    while (expected == null or offset < expected.?) {

        const want = if (expected) |length| @min(chunk.len, @as(usize, @intCast(length - offset))) else chunk.len;
        var filled: usize = 0;

        while (filled < want) {

            const length = try connection_http.recv(chunk[filled..want]);

            if (length == 0) break;

            filled += length;

        }

        if (filled == 0) break;

        const written = try client.write(file, offset, chunk[0..filled]);

        if (written != filled) return error.WriteFailed;

        offset += written;

    }

    if (expected) |length| {

        if (offset != length) return error.Truncated;

    }

    var message: [192]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "Downloaded {s} ({d} bytes).", .{ task_name[0..task_name_len], offset }) catch "Download complete.";

    finish_success(text);

}

fn format_request_head(
    out: []u8,
    url: lib.url.Url,
    method: []const u8,
    authorization: []const u8,
    content_type: ?[]const u8,
    content_length: ?u64,
) ![]const u8 {

    var stream = std.io.fixedBufferStream(out);
    const writer = stream.writer();

    try writer.print("{s} {s} HTTP/1.0\r\nHost: {s}", .{ method, url.path, url.host });

    if (url.port != 80 and url.port != 443) try writer.print(":{d}", .{url.port});

    try writer.print("\r\nAuthorization: {s}\r\nConnection: close\r\n", .{authorization});

    if (content_type) |value| try writer.print("Content-Type: {s}\r\n", .{value});
    if (content_length) |value| try writer.print("Content-Length: {d}\r\n", .{value});

    try writer.writeAll("\r\n");

    return stream.getWritten();

}

fn append_text(out: []u8, length: *usize, text: []const u8) !void {

    if (length.* + text.len > out.len) return error.NoSpaceLeft;

    @memcpy(out[length.*..][0..text.len], text);
    length.* += text.len;

}

fn append_json_string(out: []u8, length: *usize, text: []const u8) !void {

    try append_text(out, length, "\"");

    for (text) |byte| {

        switch (byte) {

            '"' => try append_text(out, length, "\\\""),
            '\\' => try append_text(out, length, "\\\\"),
            '\n' => try append_text(out, length, "\\n"),
            '\r' => try append_text(out, length, "\\r"),
            '\t' => try append_text(out, length, "\\t"),
            0...8, 11...12, 14...31 => try append_text(out, length, "?"),
            else => {

                if (length.* >= out.len) return error.NoSpaceLeft;

                out[length.*] = byte;
                length.* += 1;

            },

        }

    }

    try append_text(out, length, "\"");

}

fn basename(path: []const u8) []const u8 {

    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;

    return path[slash + 1 ..];

}

fn safe_filename(name: []const u8, out: []u8) []const u8 {

    const length = @min(name.len, out.len);

    for (name[0..length], 0..) |byte, index| {

        out[index] = if (byte == '"' or byte == '\\' or byte < 32) '_' else byte;

    }

    return out[0..length];

}

fn copy_node(out: *Node, wire: WireNode) void {

    out.id_len = copy_text(&out.id, wire.id);
    out.name_len = copy_text(&out.name, wire.name);
    out.mime_len = copy_text(&out.mime, wire.mimeType);
    out.size = wire.size;
    out.folder = std.mem.eql(u8, wire.kind, "folder");
    out.public = wire.public;
    out.failed = std.mem.eql(u8, wire.sync, "failed");

}

fn set_folder(out: *Folder, id: []const u8, name: []const u8) void {

    out.id_len = copy_text(&out.id, id);
    out.name_len = copy_text(&out.name, name);

}

fn copy_text(out: []u8, text: []const u8) usize {

    const length = @min(out.len, text.len);

    @memcpy(out[0..length], text[0..length]);

    return length;

}

fn finish_success(text: []const u8) void {

    lock.acquire();

    @atomicStore(u32, &busy, 0, .release);
    set_status_locked(text, false);

    lock.release();

    notify_ui();

}

fn finish_error(text: []const u8) void {

    lock.acquire();

    @atomicStore(u32, &busy, 0, .release);
    set_status_locked(text, true);

    lock.release();

    notify_ui();

}

fn expire_session() void {

    clear_session();

    @memset(&session_token, 0);
    session_token_len = 0;

    lock.acquire();

    screen = .setup;
    node_count = 0;
    folder_count = 0;
    selected = null;
    scroll = 0;
    @atomicStore(u32, &busy, 0, .release);
    set_status_locked("Your Sprout CDN session expired. Sign in again.", true);

    lock.release();

    notify_ui();

}

fn set_status(text: []const u8, bad: bool) void {

    lock.acquire();
    set_status_locked(text, bad);
    lock.release();

}

fn set_status_locked(text: []const u8, bad: bool) void {

    status_len = copy_text(&status, text);
    status_bad = bad;

}

fn notify_ui() void {

    @atomicStore(u32, &tick, 1, .release);
    sys.notify(ready, proto.window.ring_bit) catch {};

}

fn busy_now() bool {

    return @atomicLoad(u32, &busy, .acquire) != 0;

}

fn update_cursor(x: i32, y: i32) void {

    if (screen == .setup and (login_email_rect().contains(x, y) or password_rect().contains(x, y))) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (modal != .none and modal != .delete and prompt_rect().contains(x, y)) {

        lib.cursor.set(&connection, .selector);
        return;

    }

    if (row_at(x, y) != null or button_at(x, y)) {

        lib.cursor.set(&connection, .clicker);
        return;

    }

    lib.cursor.set(&connection, .pointer);

}

fn button_at(x: i32, y: i32) bool {

    if (modal != .none) return modal_cancel_rect().contains(x, y) or modal_confirm_rect().contains(x, y);

    if (screen == .setup) return reveal_rect().contains(x, y) or connect_rect().contains(x, y);

    return back_rect().contains(x, y) or refresh_rect().contains(x, y) or account_rect().contains(x, y) or shared_rect().contains(x, y) or
        new_folder_rect().contains(x, y) or upload_rect().contains(x, y) or primary_rect().contains(x, y) or
        rename_rect().contains(x, y) or public_rect().contains(x, y) or delete_rect().contains(x, y);

}

fn login_email_rect() Rect {

    const card = setup_card_rect();

    return .{ .x = card.x + 28, .y = card.y + 92, .w = card.w - 56, .h = 32 };

}

fn password_rect() Rect {

    const card = setup_card_rect();

    return .{ .x = card.x + 28, .y = card.y + 158, .w = card.w - 128, .h = 32 };

}

fn reveal_rect() Rect {

    const field = password_rect();

    return .{ .x = field.x + field.w + 8, .y = field.y, .w = 64, .h = field.h };

}

fn connect_rect() Rect {

    const card = setup_card_rect();

    return .{ .x = card.x + card.w - 148, .y = card.y + card.h - 58, .w = 120, .h = 34 };

}

fn setup_card_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const card_w = @min(620, width - 40);
    const card_h = @min(340, height - 40);

    return .{ .x = @divTrunc(width - card_w, 2), .y = @divTrunc(height - card_h, 2), .w = card_w, .h = card_h };

}

fn back_rect() Rect {

    return .{ .x = margin, .y = 9, .w = 60, .h = 30 };

}

fn refresh_rect() Rect {

    return .{ .x = 80, .y = 9, .w = 84, .h = 30 };

}

fn account_rect() Rect {

    return .{ .x = 174, .y = 9, .w = 88, .h = 30 };

}

fn shared_rect() Rect {

    const width: i32 = @intCast(window.surface.width);

    return .{ .x = width - margin - 92, .y = 9, .w = 92, .h = 30 };

}

fn upload_rect() Rect {

    const shared_button = shared_rect();

    return .{ .x = shared_button.x - 92, .y = 9, .w = 82, .h = 30 };

}

fn new_folder_rect() Rect {

    const upload_button = upload_rect();

    return .{ .x = upload_button.x - 110, .y = 9, .w = 100, .h = 30 };

}

fn list_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);
    const top = toolbar_h + account_h + table_header_h + table_gap_h;

    return .{ .x = margin, .y = top, .w = width - margin * 2, .h = @max(0, height - top - footer_h) };

}

fn visible_rows() usize {

    return @intCast(@max(1, @divTrunc(list_rect().h, row_h)));

}

fn row_at(x: i32, y: i32) ?usize {

    if (screen == .setup or modal != .none) return null;

    const list = list_rect();

    if (!list.contains(x, y)) return null;

    const row: usize = @intCast(@divTrunc(y - list.y, row_h));
    const index = scroll + row;

    if (index >= node_count) return null;

    return if (row_rect(list, row).contains(x, y)) index else null;

}

fn row_rect(list: Rect, row: usize) Rect {

    return .{

        .x = list.x + 2,
        .y = list.y + @as(i32, @intCast(row)) * row_h + 2,
        .w = list.w - 4,
        .h = row_h - 4,

    };

}

fn primary_rect() Rect {

    const height: i32 = @intCast(window.surface.height);

    return .{ .x = margin, .y = height - 38, .w = 90, .h = 28 };

}

fn rename_rect() Rect {

    const primary = primary_rect();

    return .{ .x = primary.x + primary.w + 8, .y = primary.y, .w = 82, .h = primary.h };

}

fn public_rect() Rect {

    const rename_button = rename_rect();

    return .{ .x = rename_button.x + rename_button.w + 8, .y = rename_button.y, .w = 106, .h = rename_button.h };

}

fn delete_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const primary = primary_rect();

    return .{ .x = width - margin - 72, .y = primary.y, .w = 72, .h = primary.h };

}

fn modal_rect() Rect {

    const width: i32 = @intCast(window.surface.width);
    const height: i32 = @intCast(window.surface.height);

    return .{ .x = @divTrunc(width - 420, 2), .y = @divTrunc(height - 180, 2), .w = 420, .h = 180 };

}

fn prompt_rect() Rect {

    const frame = modal_rect();

    return .{ .x = frame.x + 22, .y = frame.y + 62, .w = frame.w - 44, .h = 32 };

}

fn modal_cancel_rect() Rect {

    const frame = modal_rect();

    return .{ .x = frame.x + frame.w - 198, .y = frame.y + frame.h - 48, .w = 82, .h = 30 };

}

fn modal_confirm_rect() Rect {

    const frame = modal_rect();

    return .{ .x = frame.x + frame.w - 104, .y = frame.y + frame.h - 48, .w = 82, .h = 30 };

}

fn paint() void {

    lock.acquire();
    defer lock.release();

    const surface = &window.surface;

    surface.fill(ui.theme.window_bg);

    if (screen == .setup) {

        paint_setup(surface);

    } else {

        paint_browser(surface);

    }

    if (modal != .none) paint_modal(surface);

    picker.paint(surface, @intCast(surface.width), @intCast(surface.height));

    window.present_all() catch {};

}

fn paint_setup(surface: *const gfx.Surface) void {

    const card = setup_card_rect();

    ui.fill_round_rect(surface, card, 10, ui.theme.surface);
    ui.stroke_round_rect(surface, card, 10, 1, ui.theme.border);

    lib.draw.vector.icon_in(surface, .{ .x = card.x + 28, .y = card.y + 24, .w = 34, .h = 34 }, lib.icons.file, ui.theme.accent);
    font.draw(surface, card.x + 76, card.y + 23, 21, "Sign in to Sprout", ui.theme.text);

    font.draw(surface, login_email_rect().x, login_email_rect().y - 20, 12, "Email", ui.theme.text_dim);
    ui.paint_text_field(surface, &font, login_email_rect(), &login_email_field, "you@example.com", focused == .email, true, 13);

    font.draw(surface, password_rect().x, password_rect().y - 20, 12, "Password", ui.theme.text_dim);
    paint_password_field(surface);
    paint_button(surface, reveal_rect(), if (reveal_password) "Hide" else "Show", false, false);

    font.draw(surface, card.x + 28, card.y + 224, 11, "New to Sprout? sprout.software/register", ui.theme.text_faint);

    if (status_len != 0) font.draw(surface, card.x + 28, card.y + card.h - 45, 11, status[0..status_len], if (status_bad) ui.theme.warn else ui.theme.text_dim);

    paint_button(surface, connect_rect(), if (busy_now()) "Signing in..." else "Sign in", true, false);

}

fn paint_password_field(surface: *const gfx.Surface) void {

    if (reveal_password) {

        ui.paint_text_field(surface, &font, password_rect(), &password_field, "Password", focused == .password, true, 13);
        return;

    }

    var mask_storage: [256]u8 = undefined;
    @memset(mask_storage[0..password_field.len], '*');

    var masked = ui.EditBuffer{ .bytes = &mask_storage };

    masked.len = password_field.len;
    masked.cursor = password_field.cursor;
    masked.anchor = password_field.anchor;

    ui.paint_text_field(surface, &font, password_rect(), &masked, "Password", focused == .password, true, 13);

}

fn paint_browser(surface: *const gfx.Surface) void {

    const width: i32 = @intCast(surface.width);
    const height: i32 = @intCast(surface.height);

    surface.fill_rect(.{ .x = 0, .y = 0, .w = width, .h = toolbar_h }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = toolbar_h, .w = width, .h = 1 }, ui.theme.border);

    paint_button(surface, back_rect(), "Back", false, screen == .files and folder_count <= 1);
    paint_icon_button(surface, refresh_rect(), lib.icons.refresh_cw, "Refresh", false, busy_now());
    paint_icon_button(surface, account_rect(), lib.icons.log_out, "Sign out", false, busy_now());

    if (screen == .files) {

        paint_icon_button(surface, new_folder_rect(), lib.icons.folder_plus, "New folder", false, busy_now());
        paint_icon_button(surface, upload_rect(), lib.icons.file_up, "Upload", true, busy_now());

    }

    paint_icon_button(surface, shared_rect(), if (screen == .shared) lib.icons.file else lib.icons.users, if (screen == .shared) "My files" else "Shared", screen == .shared, busy_now());

    paint_account(surface, width);
    paint_table_header(surface, width);
    paint_rows(surface);

    surface.fill_rect(.{ .x = 0, .y = height - footer_h, .w = width, .h = footer_h }, ui.theme.surface_alt);
    surface.fill_rect(.{ .x = 0, .y = height - footer_h, .w = width, .h = 1 }, ui.theme.border);

    if (selected_node()) |node| {

        if (node.folder and screen == .files) {

            paint_button(surface, primary_rect(), "Open", true, busy_now());

        } else {

            paint_icon_button(surface, primary_rect(), lib.icons.file_down, "Download", true, busy_now() or node.folder and screen == .shared);

        }

        if (screen == .files) {

            paint_button(surface, rename_rect(), "Rename", false, busy_now());
            paint_button(surface, public_rect(), if (node.public) "Make private" else "Make public", false, busy_now());
            paint_button(surface, delete_rect(), "Delete", false, busy_now());

        }

    }

    if (status_len != 0) {

        const start_x = if (selected != null) public_rect().x + public_rect().w + 14 else margin;
        const available = @max(0, delete_rect().x - start_x - 10);
        const visible = ui.truncate(&font, status[0..status_len], 11, available);
        const y = height - footer_h + @divTrunc(footer_h - font.line_height(11), 2);

        font.draw(surface, start_x, y, 11, visible, if (status_bad) ui.theme.warn else ui.theme.text_dim);

    }

}

fn paint_account(surface: *const gfx.Surface, width: i32) void {

    const y = toolbar_h + 1;
    const title = if (screen == .shared) "Shared with me" else breadcrumb();

    font.draw(surface, margin, y + 9, 13, title, ui.theme.text);

    var usage_buffer: [48]u8 = undefined;
    const usage_text = format_usage(&usage_buffer, storage_used);
    const account = email[0..email_len];
    var account_buffer: [192]u8 = undefined;
    const right = try_text_pair(account, usage_text, &account_buffer);
    const text_w = font.text_width(right, 11);

    font.draw(surface, width - margin - text_w, y + 10, 11, right, ui.theme.text_dim);

}

fn breadcrumb() []const u8 {

    if (folder_count == 0) return "My files";

    return folders[folder_count - 1].name_slice();

}

fn try_text_pair(left: []const u8, right: []const u8, out: []u8) []const u8 {

    return std.fmt.bufPrint(out, "{s}  ·  {s}", .{ left, right }) catch left;

}

fn format_usage(out: []u8, bytes: u64) []const u8 {

    if (bytes >= 1024 * 1024 * 1024) return std.fmt.bufPrint(out, "{d}.{d} GB used", .{ bytes / (1024 * 1024 * 1024), bytes % (1024 * 1024 * 1024) * 10 / (1024 * 1024 * 1024) }) catch "";
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(out, "{d}.{d} MB used", .{ bytes / (1024 * 1024), bytes % (1024 * 1024) * 10 / (1024 * 1024) }) catch "";

    return std.fmt.bufPrint(out, "{d} KB used", .{bytes / 1024}) catch "";

}

fn paint_table_header(surface: *const gfx.Surface, width: i32) void {

    const y = toolbar_h + account_h;

    surface.fill_rect(.{ .x = 0, .y = y, .w = width, .h = table_header_h }, ui.theme.window_bg);
    surface.fill_rect(.{ .x = 0, .y = y + table_header_h - 1, .w = width, .h = 1 }, ui.theme.border);

    font.draw(surface, margin + 38, y + 7, 11, "Name", ui.theme.text_faint);
    font.draw(surface, width - 256, y + 7, 11, "Size", ui.theme.text_faint);
    font.draw(surface, width - 148, y + 7, 11, "Access", ui.theme.text_faint);

}

fn paint_rows(surface: *const gfx.Surface) void {

    const list = list_rect();
    const clipped = surface.clipped(list);
    const width: i32 = @intCast(surface.width);
    var row: usize = 0;
    var index = scroll;

    while (row < visible_rows() and index < node_count) : ({

        row += 1;
        index += 1;

    }) {

        const node = &nodes[index];
        const rect = row_rect(list, row);
        const fill = if (selected == index) ui.theme.active else if (row % 2 == 1) ui.theme.surface_alt else ui.theme.surface;
        const border = if (selected == index) ui.theme.accent else ui.theme.border;

        ui.fill_round_rect(&clipped, rect, 6, fill);
        ui.stroke_round_rect(&clipped, rect, 6, 1, border);

        lib.draw.vector.icon_in(&clipped, .{ .x = rect.x + 8, .y = rect.y + 6, .w = 22, .h = 22 }, if (node.folder) lib.icons.folder else lib.icons.file, if (node.folder) ui.theme.accent else ui.theme.text_dim);

        const name_width = @max(40, width - 340);
        const visible_name = ui.truncate(&font, node.name_slice(), 13, name_width);

        font.draw(&clipped, rect.x + 38, rect.y + 8, 13, visible_name, if (node.failed) ui.theme.warn else ui.theme.text);

        var size_buffer: [32]u8 = undefined;
        const size = if (node.folder) "—" else format_size(&size_buffer, node.size);

        font.draw(&clipped, width - 256, rect.y + 9, 11, size, ui.theme.text_dim);
        font.draw(&clipped, width - 148, rect.y + 9, 11, if (node.public) "Public" else "Private", if (node.public) ui.theme.good else ui.theme.text_dim);

    }

    if (node_count == 0 and !busy_now()) {

        const empty = if (screen == .shared) "Nothing has been shared with you." else "This folder is empty.";

        font.draw(&clipped, list.x + 12, list.y + 18, 13, empty, ui.theme.text_faint);

    }

}

fn format_size(out: []u8, bytes: u64) []const u8 {

    if (bytes >= 1024 * 1024 * 1024) return std.fmt.bufPrint(out, "{d}.{d} GB", .{ bytes / (1024 * 1024 * 1024), bytes % (1024 * 1024 * 1024) * 10 / (1024 * 1024 * 1024) }) catch "";
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(out, "{d}.{d} MB", .{ bytes / (1024 * 1024), bytes % (1024 * 1024) * 10 / (1024 * 1024) }) catch "";
    if (bytes >= 1024) return std.fmt.bufPrint(out, "{d}.{d} KB", .{ bytes / 1024, bytes % 1024 * 10 / 1024 }) catch "";

    return std.fmt.bufPrint(out, "{d} B", .{bytes}) catch "";

}

fn paint_modal(surface: *const gfx.Surface) void {

    const frame = modal_rect();

    surface.fill_rect_alpha(surface.bounds(), lib.draw.rgb(0, 0, 0), 120);
    ui.fill_round_rect(surface, frame, 9, ui.theme.surface);
    ui.stroke_round_rect(surface, frame, 9, 1, ui.theme.border);

    const title: []const u8 = switch (modal) {

        .new_folder => "New folder",
        .rename => "Rename item",
        .delete => "Delete item?",
        .none => "",

    };

    font.draw(surface, frame.x + 22, frame.y + 18, 16, title, ui.theme.text);

    if (modal == .delete) {

        const node = selected_node();
        var message: [180]u8 = undefined;
        const text = if (node) |item| std.fmt.bufPrint(&message, "Delete {s}? This cannot be undone.", .{item.name_slice()}) catch "Delete this item?" else "Delete this item?";

        font.draw(surface, frame.x + 22, frame.y + 65, 12, ui.truncate(&font, text, 12, frame.w - 44), ui.theme.text_dim);

    } else {

        ui.paint_text_field(surface, &font, prompt_rect(), &prompt_field, "Name", true, true, 13);

    }

    paint_button(surface, modal_cancel_rect(), "Cancel", false, false);
    paint_button(surface, modal_confirm_rect(), if (modal == .delete) "Delete" else "Save", true, false);

}

fn paint_button(surface: *const gfx.Surface, rect: Rect, label: []const u8, primary: bool, disabled: bool) void {

    const fill = if (disabled) ui.theme.surface else if (primary) ui.theme.accent_dim else ui.theme.surface_alt;
    const color = if (disabled) ui.theme.text_faint else ui.theme.text;

    ui.fill_round_rect(surface, rect, 5, fill);
    ui.stroke_round_rect(surface, rect, 5, 1, if (primary and !disabled) ui.theme.accent else ui.theme.border);

    const visible = ui.truncate(&font, label, 12, rect.w - 12);
    const x = rect.x + @divTrunc(rect.w - font.text_width(visible, 12), 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(12), 2);

    font.draw(surface, x, y, 12, visible, color);

}

fn paint_icon_button(surface: *const gfx.Surface, rect: Rect, icon: []const u8, label: []const u8, primary: bool, disabled: bool) void {

    const fill = if (disabled) ui.theme.surface else if (primary) ui.theme.accent_dim else ui.theme.surface_alt;
    const color = if (disabled) ui.theme.text_faint else ui.theme.text;
    const icon_size: i32 = 14;
    const gap: i32 = 5;

    ui.fill_round_rect(surface, rect, 5, fill);
    ui.stroke_round_rect(surface, rect, 5, 1, if (primary and !disabled) ui.theme.accent else ui.theme.border);

    const visible = ui.truncate(&font, label, 12, rect.w - icon_size - gap - 12);
    const content_w = icon_size + gap + font.text_width(visible, 12);
    const x = rect.x + @divTrunc(rect.w - content_w, 2);
    const y = rect.y + @divTrunc(rect.h - font.line_height(12), 2);

    lib.draw.vector.icon_in(surface, .{ .x = x, .y = rect.y + @divTrunc(rect.h - icon_size, 2), .w = icon_size, .h = icon_size }, icon, color);
    font.draw(surface, x + icon_size + gap, y, 12, visible, color);

}

test "JSON strings escape request data" {

    var out: [64]u8 = undefined;
    var length: usize = 0;

    try append_json_string(&out, &length, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out[0..length]);

}

test "filenames are safe in multipart headers" {

    var out: [32]u8 = undefined;

    try std.testing.expectEqualStrings("a_b_c", safe_filename("a\"b\\c", &out));

}

test "session token accepts callback fragments" {

    try std.testing.expectEqualStrings("abc.def", normalize_token("https://cdn.example/#auth=abc.def"));
    try std.testing.expectEqualStrings("abc.def", normalize_token(" auth=abc.def "));

}

test "extracts Sprout session cookie" {

    var out: [64]u8 = undefined;
    const headers = "Content-Type: application/json\r\nSet-Cookie: sprout_session=header.payload.signature; Path=/; HttpOnly";
    const length = find_cookie(headers, "sprout_session", &out).?;

    try std.testing.expectEqualStrings("header.payload.signature", out[0..length]);

}

test "parses CDN OAuth redirect" {

    const location = "https://sprout.software/oauth/authorize?response_type=code&client_id=client_123&redirect_uri=https%3A%2F%2Fcdn.sprout.software%2Fapi%2Fv1%2Fauth%2Fcallback&scope=identity+offline_access&state=state_123&code_challenge=challenge_123&code_challenge_method=S256";
    const request = try parse_oauth_request(location);

    try std.testing.expectEqualStrings("client_123", request.client_id[0..request.client_id_len]);
    try std.testing.expectEqualStrings("https://cdn.sprout.software/api/v1/auth/callback", request.redirect_uri[0..request.redirect_uri_len]);
    try std.testing.expectEqualStrings("identity offline_access", request.scope[0..request.scope_len]);
    try std.testing.expectEqualStrings("state_123", request.state[0..request.state_len]);
    try std.testing.expectEqualStrings("challenge_123", request.challenge[0..request.challenge_len]);

}

test "OAuth redirects stay on production HTTPS origins" {

    try std.testing.expect(trusted_https_url("https://sprout.software/oauth/authorize", "sprout.software"));
    try std.testing.expect(!trusted_https_url("http://sprout.software/oauth/authorize", "sprout.software"));
    try std.testing.expect(!trusted_https_url("https://example.com/oauth/authorize", "sprout.software"));

}

test "CDN consent accepts only documented scopes" {

    try std.testing.expect(valid_cdn_scopes("identity offline_access"));
    try std.testing.expect(valid_cdn_scopes("offline_access identity"));
    try std.testing.expect(!valid_cdn_scopes("identity"));
    try std.testing.expect(!valid_cdn_scopes("identity offline_access admin"));

}
