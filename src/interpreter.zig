const std = @import("std");
const jam = @import("jam");
const readline = @import("readline");
const history = @import("history");
const jig = @import("jig");

const stdout = std.io.getStdOut().writer();

const history_file = "/tmp/.jig_history.tmp";

const PrimitiveTag = enum {
  Undefined,
  Null,
  Boolean,
  Number,
  Bigint,
  String,
  Symbol,
};

const PrimitiveValue = union(PrimitiveTag) {
  Undefined: void,
  Null: void,
  Boolean: bool,
  Number: f64,
  Bigint: i128, // good enough for now
  String: []const u8,
  Symbol: u64, // just a counter for now
};

const ObjectTag = enum {
  Object,
  Function,
};

const Object = struct {

};

const Function = struct {

};

const ObjectValue = union(ObjectTag) {
  Object: Object,
  Function: Function,
};

const Value = union {
  Object: ObjectValue,
  Primitive: PrimitiveValue,
};

const LexicalScope = struct {
  outer: ?*const LexicalScope,
  environment: std.StringHashMap(Value),

  const Self = @This();

  fn init(allocator: std.mem.Allocator, outer: ?*const LexicalScope) Self {
    return Self{
      .outer = outer,
      .environment = std.StringHashMap(Value).init(allocator),
    };
  }

  fn get(self: Self, name: []const u8) ?Value {
    if (self.environment.get(name)) |value| {
      return value;
    }
    self.outer.get(name);
  }

  fn put(self: Self, name: []const u8, value: Value) std.mem.Allocator.Error!void {
    return self.environment.put(name, value);
  }
};

// der: Declarative Environment Record, the global topmost lexical environment
// globalThis: A global object
pub fn interpret(allocator: std.mem.Allocator, ast: *const jam.Parser.Result, der: *LexicalScope,
  globalThis: *Object) ![]const u8 {
  _ = ast;
  _ = der;
  _ = globalThis;
  return allocator.dupe(u8, "undefined");
}

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  defer std.debug.assert(gpa.deinit() == .ok);

  _ = history.read_history(history_file);

  // Declarative Environment Record
  var der = LexicalScope.init(allocator, null);
  var globalThis = Object{};
  while (true) {
    const command = readline.readline("> ");
    if (command == null) {
      try stdout.print("^D\n", .{});
      break;
    }

    if (std.mem.len(command) == 0) {
      continue;
    }

    _ = history.add_history(command);

    var parser = try jam.Parser.init(allocator, std.mem.span(command), .{ .source_type = .script });
    defer parser.deinit();

    if (parser.parse()) |*ast| {
      defer @constCast(ast).deinit();
      const pretty_string = try interpret(allocator, ast, &der, &globalThis);
      defer allocator.free(pretty_string);
      try stdout.print("{s}\n", .{ pretty_string });
    } else |err| {
      std.log.err("error: {any}", .{ err });

      for (parser.diagnostics.items) |d| {
          std.log.err("error:{d}:{d} {s}", .{ d.coord.line + 1, d.coord.column, d.message });
      }

      const n_errors = parser.diagnostics.items.len;
      std.log.err("found {d} error{c}", .{ n_errors, @as(u8, if (n_errors == 1) ' ' else 's') });
    }
  }

  _ = history.write_history(history_file);
}
