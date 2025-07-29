const std = @import("std");
const jam = @import("jam");
const jig = @import("jig");
const cli = @import("cli.zig");

const stdout = std.io.getStdOut().writer();

const history_file = "/tmp/.jig_history.tmp";

/// Return the type of a field of a union
fn GetReturnType(comptime UnionType: type, tag: std.meta.Tag(UnionType)) type {
  return @typeInfo(UnionType).@"union".fields[@intFromEnum(tag)].type;
}

const PrimitiveTag = enum {
  @"undefined",
  @"null",
  boolean,
  number,
  bigint,
  string,
  symbol,
};

const PrimitiveValue = union(PrimitiveTag) {
  @"undefined": void,
  @"null": void,
  boolean: bool,
  number: f64,
  bigint: i128, // good enough for now
  string: []const u8,
  symbol: u64, // just a counter for now

  pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
    switch (self) {
      .@"undefined" => unreachable,
      .@"null" => unreachable,
      .boolean => unreachable,
      .number => |n| return try std.fmt.allocPrint(allocator, "{d}", .{ n }),
      .bigint => unreachable,
      .string => unreachable,
      .symbol => unreachable,
    }
  }
};

const ObjectTag = enum {
  object,
  function,
};

const Object = struct {

};

const Function = struct {

};

const ObjectValue = union(ObjectTag) {
  object: Object,
  function: Function,

  pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
    _ = self;
    return allocator.dupe(u8, "?");
  }
};

const ValueTag = enum {
  object,
  primitive,
};

const Value = union(ValueTag) {
  object: ObjectValue,
  primitive: PrimitiveValue,

  pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
    switch (self) {
      .object => |o| { return o.toString(allocator); },
      .primitive => |p| { return p.toString(allocator); },
    }
  }

  pub fn getPrimitiveAs(self: @This(), comptime tag: PrimitiveTag) GetReturnType(PrimitiveValue, tag) {
    switch (self) {
      .primitive => |p| {
        switch (p) {
          .number => |number| {
            if (tag != .number) {
              unreachable;
            }
            return number;
          },
          else => unreachable,
        }
      },
      else => unreachable,
    }
  }
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

pub fn walk(tree: *const jam.Parser.Tree, index: jam.Ast.Node.Index) Value {
  const node = tree.nodes.get(@intFromEnum(index));
  return switch (node.data) {
    .program => |sub_range| {
      if (sub_range) |sr| {
        for (sr.asSlice(tree)) |i| {
          return walk(tree, i);
        }
      }
      unreachable;
    },
    .assignment_expr => |binaryPayload| { _ = binaryPayload; unreachable; },
    .binary_expr => |binary_payload| {
      const lhs = walk(tree, binary_payload.lhs);
      const rhs = walk(tree, binary_payload.rhs);
      const operator = binary_payload.getOperatorKind(tree);
      switch (operator) {
        .@"+", .@"-", .@"*", .@"/", .@"**" => {
          switch (lhs) {
            .primitive => |p| {
              switch (p) {
                .number => |lhs_number| {
                  const rhs_number = rhs.getPrimitiveAs(.number);
                  switch (operator) {
                    .@"+" => return Value{ .primitive = PrimitiveValue{ .number = lhs_number + rhs_number } },
                    .@"-" => return Value{ .primitive = PrimitiveValue{ .number = lhs_number - rhs_number } },
                    .@"*" => return Value{ .primitive = PrimitiveValue{ .number = lhs_number * rhs_number } },
                    .@"/" => return Value{ .primitive = PrimitiveValue{ .number = lhs_number / rhs_number } },
                    .@"**" => return Value{ .primitive = PrimitiveValue{ .number = std.math.pow(f64, lhs_number, rhs_number) } },
                    else => std.debug.panic("operator {} not implemented", .{ operator }),
                  }
                },
                else => std.debug.panic("type of {} not implemented", .{ p }),
              }
            },
            else => std.debug.panic("type of {} not implemented", .{ lhs }),
          }
        },
        else => std.debug.panic("operator {} not implemented", .{ operator }),
      }
    },
    .member_expr => |propertyAccess| { _ = propertyAccess; unreachable; },
    .computed_member_expr => |computedPropertyAccess| { _ = computedPropertyAccess; unreachable; },
    .tagged_template_expr => |taggedTemplateExpression| { _ = taggedTemplateExpression; unreachable; },
    .meta_property => |metaProperty| { _ = metaProperty; unreachable; },
    .arguments => |subRange| { _ = subRange; unreachable; },
    .new_expr => |newExpr| { _ = newExpr; unreachable; },
    .call_expr => |callExpr| { _ = callExpr; unreachable; },
    .super_call_expr => |subRange| { _ = subRange; unreachable; },
    .super => |token_index| { _ = token_index; unreachable; },
    .optional_expr => |node_index| { _ = node_index; unreachable; },
    .function_expr => |function| { _ = function; unreachable; },

    .post_unary_expr => |unaryPayload| { _ = unaryPayload; unreachable; },
    .unary_expr => |unary_payload| {
      const operator = unary_payload.getOperatorKind(tree);
      const operand = walk(tree, unary_payload.operand);
      switch (operator) {
        .@"-" => {
          switch (operand) {
            .primitive => |p| {
              switch (p) {
                .number => |number| {
                  switch (operator) {
                    .@"-" => return Value{ .primitive = PrimitiveValue{ .number = -number } },
                    else => std.debug.panic("operator {} not implemented", .{ operator }),
                  }
                },
                else => std.debug.panic("type of {} not implemented", .{ p }),
              }
            },
            else => std.debug.panic("type of {} not implemented", .{ operand }),
          }
        },
        else => std.debug.panic("operator {} not implemented", .{ operator }),
      }
    },
    .await_expr => |unaryPayload| { _ = unaryPayload; unreachable; },
    .yield_expr => |yieldPayload| { _ = yieldPayload; unreachable; },
    .update_expr => |unaryPayload| { _ = unaryPayload; unreachable; },

    .identifier => |token_index| { _ = token_index; unreachable; },
    .identifier_reference => |token_index| { _ = token_index; unreachable; },
    .binding_identifier => |token_index| { _ = token_index; unreachable; },

    .string_literal => |token_index| { _ = token_index; unreachable; },
    .number_literal => |number| {
      return Value{ .primitive = PrimitiveValue{ .number = number.value(tree) } };
    },
    .boolean_literal => |boolean| { _ = boolean; unreachable; },
    .null_literal => |token_index| { _ = token_index; unreachable; },
    .regex_literal => |token_index| { _ = token_index; unreachable; },

    .this => |token_index| { _ = token_index; unreachable; },
    .empty_array_item => { unreachable; },
    .array_literal => |subRange| { _ = subRange; unreachable; },
    .array_pattern => |subRange| { _ = subRange; unreachable; },
    .spread_element => |node_index| { _ = node_index; unreachable; },
    .rest_element => |node_index| { _ = node_index; unreachable; },
    .object_literal => |subRange| { _ = subRange; unreachable; },
    .object_property => |propertyDefinition| { _ = propertyDefinition; unreachable; },
    .shorthand_property => |shorthandProperty| { _ = shorthandProperty; unreachable; },
    .class_expression => |class| { _ = class; unreachable; },
    .class_meta => |classMeta| { _ = classMeta; unreachable; },
    .class_field => |classFieldDefinition| { _ = classFieldDefinition; unreachable; },
    .class_method => |classFieldDefinition| { _ = classFieldDefinition; unreachable; },
    .sequence_expr => |subRange| { _ = subRange; unreachable; },
    .parenthesized_expr => |node_index| return walk(tree, node_index),
    .conditional_expr => |conditional| { _ = conditional; unreachable; },
    .template_literal => |subRange| { _ = subRange; unreachable; },
    .template_element => |token_index| { _ = token_index; unreachable; },
    .assignment_pattern => |binaryPayload| { _ = binaryPayload; unreachable; },
    .object_pattern => |subRange| { _ = subRange; unreachable; },

    .empty_statement => { unreachable; },
    .labeled_statement => |labeledStatement| { _ = labeledStatement; unreachable; },
    .try_statement => |tryStatement| { _ = tryStatement; unreachable; },
    .catch_clause => |catchClause| { _ = catchClause; unreachable; },

    .block_statement => |subRange| { _ = subRange; unreachable; },
    .statement_list => |subRange| { _ = subRange; unreachable; },
    .expression_statement => |node_index| return walk(tree, node_index),
    .variable_declaration => |variableDeclaration| { _ = variableDeclaration; unreachable; },
    .variable_declarator => |variableDeclarator| { _ = variableDeclarator; unreachable; },
    .function_declaration => |function| { _ = function; unreachable; },
    .function_meta => |functionMeta| { _ = functionMeta; unreachable; },
    .class_declaration => |class| { _ = class; unreachable; },
    .debugger_statement => { unreachable; },
    .if_statement => |conditional| { _ = conditional; unreachable; },
    .do_while_statement => |whileStatement| { _ = whileStatement; unreachable; },
    .while_statement => |whileStatement| { _ = whileStatement; unreachable; },
    .with_statement => |withStatement| { _ = withStatement; unreachable; },

    .throw_statement => |node_index| { _ = node_index; unreachable; },

    .for_statement => |forStatement| { _ = forStatement; unreachable; },
    .for_of_statement => |forStatement| { _ = forStatement; unreachable; },
    .for_in_statement => |forStatement| { _ = forStatement; unreachable; },

    .for_iterator => |forIterator| { _ = forIterator; unreachable; },
    .for_in_of_iterator => |forInOfIterator| { _ = forInOfIterator; unreachable; },

    .switch_statement => |switchStatement| { _ = switchStatement; unreachable; },
    .switch_case => |switchCase| { _ = switchCase; unreachable; },
    .default_case => |switchDefaultCase| { _ = switchDefaultCase; unreachable; },
    .break_statement => |jumpLabel| { _ = jumpLabel; unreachable; },
    .continue_statement => |jumpLabel| { _ = jumpLabel; unreachable; },
    .parameters => |subRange| { _ = subRange; unreachable; },
    .return_statement => |node_index| { _ = node_index; unreachable; },
    .import_declaration => |importDeclaration| { _ = importDeclaration; unreachable; },
    .import_default_specifier => |importDefaultSpecifier| { _ = importDefaultSpecifier; unreachable; },
    .import_specifier => |importSpecifier| { _ = importSpecifier; unreachable; },
    .import_namespace_specifier => |importNamespaceSpecifier| { _ = importNamespaceSpecifier; unreachable; },

    .export_declaration => |exportedDeclaration| { _ = exportedDeclaration; unreachable; },
    .export_specifier => |exportSpecifier| { _ = exportSpecifier; unreachable; },
    .export_list_declaration => |exportListDeclaration| { _ = exportListDeclaration; unreachable; },
    .export_from_declaration => |exportFromDeclaration| { _ = exportFromDeclaration; unreachable; },
    .export_all_declaration => |exportAllDeclaration| { _ = exportAllDeclaration; unreachable; },
    // jsx
    .jsx_fragment => |jsxFragment| { _ = jsxFragment; unreachable; },
    .jsx_element => |jsxElement| { _ = jsxElement; unreachable; },
    .jsx_children => |subRange| { _ = subRange; unreachable; },

    .jsx_opening_element => |jsxOpeningElement| { _ = jsxOpeningElement; unreachable; },
    .jsx_closing_element => |jsxClosingElement| { _ = jsxClosingElement; unreachable; },
    .jsx_self_closing_element => |jsxOpeningElement| { _ = jsxOpeningElement; unreachable; },
    .jsx_attribute => |jsxAttribute| { _ = jsxAttribute; unreachable; },
    .jsx_text => |token_index| { _ = token_index; unreachable; },
    .jsx_expression => |node_index| { _ = node_index; unreachable; },
    .jsx_identifier => |token_index| { _ = token_index; unreachable; },
    .jsx_identifier_reference => |token_index| { _ = token_index; unreachable; },
    .jsx_member_expression => |jsxMemberExpression| { _ = jsxMemberExpression; unreachable; },
    .jsx_namespaced_name => |jsxNamespacedName| { _ = jsxNamespacedName; unreachable; },
    .jsx_spread_child => |node_index| { _ = node_index; unreachable; },
    .jsx_spread_attribute => |node_index| { _ = node_index; unreachable; },

    .none => { unreachable; },
  };
}

// der: Declarative Environment Record, the global topmost lexical environment
// globalThis: A global object
pub fn interpret(allocator: std.mem.Allocator, ast: *const jam.Parser.Result, der: *LexicalScope,
  globalThis: *Object) !Value {
  _ = allocator;
  _ = der;
  _ = globalThis;
  return walk(ast.tree, ast.tree.root);
}

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  defer std.debug.assert(gpa.deinit() == .ok);

  // Declarative Environment Record
  var der = LexicalScope.init(allocator, null);
  var globalThis = Object{};

  while (true) {
    const result = try cli.get_command(allocator, history_file);
    if (result) |command| {
      defer allocator.free(command);
      var parser = try jam.Parser.init(allocator, command, .{ .source_type = .script });
      defer parser.deinit();

      if (parser.parse()) |*ast| {
        defer @constCast(ast).deinit();
        const value = try interpret(allocator, ast, &der, &globalThis);
        const pretty_string = value.toString(allocator);
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
    } else {
      // ^D
      break;
    }
  }
}

fn test_for_value(comptime tag: PrimitiveTag, expr: []const u8, expected_value: GetReturnType(PrimitiveValue, tag)) !void {
  const allocator = std.testing.allocator;

  var der = LexicalScope.init(allocator, null);
  var globalThis = Object{};
  var parser = try jam.Parser.init(allocator, expr, .{ .source_type = .script });
  defer parser.deinit();

  var ast = try parser.parse();
  defer ast.deinit();
  const value = try interpret(allocator, &ast, &der, &globalThis);
  try std.testing.expectEqual(expected_value, value.getPrimitiveAs(.number));
}

test "basic tests" {
  try test_for_value(.number, "1+1", 2);
  try test_for_value(.number, "1-1", 0);
  try test_for_value(.number, "3*2", 6);
  try test_for_value(.number, "4/2", 2);
  try test_for_value(.number, "3*(2+2)/2-1", 5);
  try test_for_value(.number, "2**8", 256);
  // try test_for_value(.number, "1^2", 3);
  // try test_for_value(.number, "1^3", 2);
  // try test_for_value(.number, "1&2", 0);
  // try test_for_value(.number, "1|2", 3);
  try test_for_value(.number, "-7", -7);
}
