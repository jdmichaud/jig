const std = @import("std");
const jam = @import("jam");
const readline = @import("readline");
const history = @import("history");
const jig = @import("jig");
const cli = @import("cli.zig");

const stdout = std.io.getStdOut().writer();

const history_file = "/tmp/.jig_history.tmp";

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  defer std.debug.assert(gpa.deinit() == .ok);

  while (true) {
    const result = try cli.get_command(allocator, history_file);
    if (result) |command| {
      defer allocator.free(command);
      var parser = try jam.Parser.init(allocator, command, .{ .source_type = .script });
      defer parser.deinit();
      if (parser.parse()) |*ast| {
        // Not sure why we need a constCast here
        defer @constCast(ast).deinit();
        const pretty_string = try jam.estree.toJsonString(allocator, ast.tree, .{ .start_end_locs = true });
        defer allocator.free(pretty_string);
        try stdout.print("{s}\n", .{ pretty_string });
      } else |err| {
        std.log.err("error: {any}", .{ err });

        for (parser.diagnostics.items) |d| {
            std.log.err("error:{d}:{d} {s}", .{ d.coord.line + 1, d.coord.column, d.message });
        }
      }
    } else {
      // ^D
      break;
    }
  }
}
