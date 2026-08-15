//! This is a little utility that creates a ZON file containing the full list
//! of HTML named character references (AKA HTML entities).
//!
//! The ZON file is created from a list that is read from an input JSON file.
//! This input JSON file can be retrieved from
//! <https://html.spec.whatwg.org/entities.json>.
//!
//! The list written by this program is always sorted by character reference
//! name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;
const Io = std.Io;
const json = std.json;
const zon = std.zon;

const Error = error{
    InvalidInputFile,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    const input_path = args[1];
    const output_path = args[2];

    const cwd = fs.cwd();

    var in_file = try cwd.openFile(input_path, .{});
    defer in_file.close();

    var in_buf: [128]u8 = undefined;
    var in_reader = in_file.reader(&in_buf);

    var out_file = try cwd.createFile(output_path, .{ .truncate = true });
    defer out_file.close();

    var out_buf: [128]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);

    processEntities(
        alloc,
        &in_reader.interface,
        &out_writer.interface,
    ) catch |err| {
        switch (err) {
            json.Error.SyntaxError, json.Error.UnexpectedEndOfInput => {
                std.debug.print(
                    \\The input JSON file did not parse correctly.
                    \\Is it a valid JSON file?
                    \\
                    ,
                    .{},
                );
                std.debug.print(
                    "Input JSON file path: {s}\n",
                    .{input_path},
                );
                std.process.exit(1);
            },
            Error.InvalidInputFile => {
                std.debug.print(
                    \\The input JSON file did not have the expected structure.
                    \\It was missing a key or was otherwise malformed.
                    \\
                    ,
                    .{},
                );
                std.debug.print(
                    "Input JSON file path: {s}\n",
                    .{input_path},
                );
                std.process.exit(1);
            },
            else => return err,
        }
    };
}

// The output ZON file is a list of these.
const Entry = struct {
    name: []const u8,
    characters: []const u8,

    fn lessThan(context: void, a: Entry, b: Entry) bool {
        _ = context;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

fn processEntities(
    alloc: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
) !void {
    var json_reader = json.Reader.init(alloc, reader);
    const entity_defs = try json.parseFromTokenSource(
        json.Value,
        alloc,
        &json_reader,
        .{},
    );

    var entries_list: ArrayList(Entry) = .empty;

    var it = blk: {
        switch (entity_defs.value) {
            .object => |o| break :blk o.iterator(),
            else => return Error.InvalidInputFile,
        }
    };
    while (it.next()) |kv| {
        const entry = try entryFromDef(kv);
        try entries_list.append(alloc, entry);
    }

    const entries = try entries_list.toOwnedSlice(alloc);
    std.mem.sort(Entry, entries, {}, Entry.lessThan);

    try zon.stringify.serialize(entries, .{}, writer);
    try writer.flush();
}

fn entryFromDef(kv: anytype) !Entry {
    const def_name = kv.key_ptr.*;
    const def_obj = kv.value_ptr.*.object;

    const name = trimEntityName(def_name);
    const characters = if (def_obj.get("characters")) |v|
        v.string
    else
        return Error.InvalidInputFile;

    return .{
        .name = name,
        .characters = characters,
    };
}

// We want to lookup entities using just the unique name, e.g. "amp" or
// "nbsp". We don't need the leading "&" and trailing ";".
fn trimEntityName(name: []const u8) []const u8 {
    const stripped_left = std.mem.trimStart(u8, name, "&");
    return std.mem.trimEnd(u8, stripped_left, ";");
}
