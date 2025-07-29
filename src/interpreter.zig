// reference:
//   - https://tc39.es/ecma262/
// zig build interpreter
// zig build test-interpreter
// zig build test-interpreter -Dtest-filter="hoist tests"
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

const ValueTag = enum {
  @"undefined",
  @"null",
  boolean,
  number,
  bigint,
  string,
  symbol,
  object,
};

const Symbol = struct {
  id: u64,

  const next_symbol: u64 = 0;
  pub fn new() Symbol {
    Symbol.next_symbol += 1;
    return Symbol{ .id = Symbol.next_symbol };
  }

  const HashContext = struct {
    pub const hash = struct {
      fn hash(ctx: Symbol, key: u64) u64 {
        _ = ctx;
        return key.id;
      }
    };
    pub const eql = struct {
      fn eql(ctx: Symbol, a: u64, b: u64) bool {
        _ = ctx;
        return a.id == b.id;
      }
    };
  };
};

const Value = union(ValueTag) {
  @"undefined": void,
  @"null": void,
  boolean: bool,
  number: f64,
  bigint: i128, // good enough for now
  string: []const u8,
  symbol: Symbol,
  object: Object,

  pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
    switch (self) {
      .@"undefined" => unreachable,
      .@"null" => unreachable,
      .boolean => unreachable,
      .number => |n| return try std.fmt.allocPrint(allocator, "{d}", .{ n }),
      .bigint => unreachable,
      .string => unreachable,
      .symbol => unreachable,
      .object => |o| { return o.toString(allocator); },
    }
  }

  pub fn getPrimitiveAs(self: @This(), comptime tag: ValueTag) GetReturnType(Value, tag) {
    switch (self) {
      .number => |number| {
        if (tag != .number) {
          unreachable;
        }
        return number;
      },
      else => unreachable,
    }
  }
};

const PropertyKey = union(enum) {
  name: []const u8,
  symbol: Symbol,
};

// 6.1.7
const Property = struct {
  key: PropertyKey,
  // The value retrieved by a get access of the property
  value: Value = Value{ .@"undefined" = {} },
  // If false, attempts by ECMAScript code to change the property's [[Value]] attribute using [[Set]] will not succeed.
  writable: bool = false,
  // If the value is an Object it must be a function object.
  // The function's [[Call]] internal method (Table 5) is called with an empty
  // arguments list to retrieve the property value each time a get access of the
  // property is performed.
  get: ?Object,
  // If the value is an Object it must be a function object.
  // The function's [[Call]] internal method (Table 5) is called with an
  // arguments list containing the assigned value as its sole argument each time
  // a set access of the property is performed. The effect of a property's
  // [[Set]] internal method may, but is not required to, have an effect on the
  // value returned by subsequent calls to the property's [[Get]] internal
  // method.
  set: ?Object,
  // If true, the property will be enumerated by a for-in enumeration (see
  // 14.7.5). Otherwise, the property is said to be non-enumerable.
  enumerable: bool = false,
  // attempts to delete the property, change it from a data property to an
  // accessor property or from an accessor property to a data property, or make
  // any changes to its attributes (other than replacing an existing [[Value]]
  // or setting [[Writable]] to false) will fail.
  configurable: bool = false,
};

const Receiver = struct{};

const SymbolProperties = std.HashMap(Symbol, Property, Symbol.HashContext,
  std.hash_map.default_max_load_percentage);

// 6.1.7 and 10.1
const Object = struct {
  allocator: std.mem.Allocator,
  name_properties: std.StringHashMap(Property),
  symbol_properties: SymbolProperties,

  prototype: ?*Object = null,
  extensible: bool = false,

  vtable: VTable,

  const Self = @This();

  fn init(allocator: std.mem.Allocator, prototype: ?*Object) Self {
    return Self{
      .allocator = allocator,
      .prototype = prototype,
      .extensible = true,
      .name_properties = std.StringHashMap(Property).init(allocator),
      .symbol_properties = SymbolProperties.init(allocator),
      .vtable = .{},
    };
  }

  const VTable = struct {
    // Determine the object that provides inherited properties for this object. A
    // null value indicates that there are no inherited properties.
    getPrototypeOf: ?*const fn (self: Self) CompletionRecord(?Object) = null,
    // Associate this object with another object that provides inherited
    // properties. Passing null indicates that there are no inherited properties.
    // Returns true indicating that the operation was completed successfully or
    // false indicating that the operation was not successful.
    setPrototypeOf: ?*const fn (self: *Self, object: ?Object) CompletionRecord(bool) = null,
    // Determine whether it is permitted to add additional properties to this
    // object.
    isExtensible: ?*const fn (self: Self) CompletionRecord(bool) = null,
    // Control whether new properties may be added to this object. Returns true if
    // the operation was successful or false if the operation was unsuccessful.
    preventExtensions: ?*const fn (self: Self) CompletionRecord(bool) = null,
    // Descriptor Return a Property Descriptor for the own property of this object
    // whose key is propertyKey, or undefined if no such property exists.
    getOwnProperty: ?*const fn (self: Self, key: PropertyKey) CompletionRecord(?Property) = null,
    // Create or alter the own property, whose key is propertyKey, to have the
    // state described by PropertyDescriptor. Return true if that property was
    // successfully created/updated or false if the property could not be created
    // or updated.
    defineOwnProperty: ?*const fn (self: *Self, key: PropertyKey, property: Property) CompletionRecord(bool) = null,
    // Return a Boolean value indicating whether this object already has either an
    // own or inherited property whose key is propertyKey.
    hasProperty: ?*const fn (self: Self, key: PropertyKey) CompletionRecord(bool) = null,
    // Return the value of the property whose key is propertyKey from this object.
    // If any ECMAScript code must be executed to retrieve the property value,
    // Receiver is used as the this value when evaluating the code.
    get: ?*const fn (self: Self, key: PropertyKey, receiver: Receiver) CompletionRecord(Value) = null,
    // Set the value of the property whose key is propertyKey to value. If any
    // ECMAScript code must be executed to set the property value, Receiver is
    // used as the this value when evaluating the code. Returns true if the
    // property value was set or false if it could not be set.
    set: ?*const fn (self: *Self, key: PropertyKey, value: Value, receiver: Receiver) CompletionRecord(bool) = null,
    // Remove the own property whose key is propertyKey from this object. Return
    // false if the property was not deleted and is still present. Return true if
    // the property was deleted or is not present.
    delete: ?*const fn (self: *Self, key: PropertyKey) CompletionRecord(bool) = null,
    // Return a List whose elements are all of the own property keys for the
    // object.
    ownPropertyKeys: ?*const fn (self: Self) CompletionRecord([]PropertyKey) = null,
  };

  // 10.1.2 #sec-ordinarygetprototypeof
  fn getPrototypeOf(self: Self) CompletionRecord(?Object) {
    if (self.vtable.getPrototypeOf) |func| {
      return func(self);
    }
    return .normalCompletion(?Object, if (self.prototype) self.prototype.* else null);
  }
  // 10.1.3 #sec-ordinarysetprototypeof
  fn setPrototypeOf(self: *Self, object: ?Object) CompletionRecord(bool) {
    if (self.vtable.setPrototypeOf) |func| {
      return func(self, object);
    }
    if (self == &Object) {
      return .boolCompletion(true);
    }
    if (!self.extensible) {
      return .boolCompletion(false);
    }
    var done = false;
    var p = object;
    while (!done) {
      if (p == null) {
        done = true;
      } else if (self == &p) {
        // No circular dependency
        return .boolCompletion(false);
      } else if (p.getPrototypeOf != self.getPrototypeOf) {
        done = true;
      } else {
        p = p.prototype;
      }
    }
    self.prototype = &object;
    return .boolCompletion(true);
  }

  fn isExtensible(self: Self) CompletionRecord(bool) {
    if (self.vtable.isExtensible) |func| {
      return func(self);
    }
    return .boolCompletion(self.extensible);
  }
  fn preventExtensions(self: Self) CompletionRecord(bool) {
    if (self.vtable.preventExtensions) |func| {
      return func(self);
    }
    unreachable;
  }
  fn getOwnProperty(self: Self, key: PropertyKey) CompletionRecord(?Property) {
    if (self.vtable.getOwnProperty) |func| {
      return func(self, key);
    }
    unreachable;
  }
  fn defineOwnProperty(self: *Self, key: PropertyKey, property: Property) CompletionRecord(bool) {
    if (self.vtable.defineOwnProperty) |func| {
      return func(self, key, property);
    }
    unreachable;
  }
  fn hasProperty(self: Self, key: PropertyKey) CompletionRecord(bool) {
    if (self.vtable.hasProperty) |func| {
      return func(self, key);
    }
    unreachable;
  }
  fn get(self: Self, key: PropertyKey, receiver: Receiver) CompletionRecord(Value) {
    if (self.vtable.get) |func| {
      return func(self, key, receiver);
    }
    unreachable;
  }
  fn set(self: *Self, key: PropertyKey, value: Value, receiver: Receiver) CompletionRecord(bool) {
    if (self.vtable.set) |func| {
      return func(self, key, value, receiver);
    }
    unreachable;
  }
  fn delete(self: *Self, key: PropertyKey) CompletionRecord(bool) {
    if (self.vtable.delete) |func| {
      return func(self, key);
    }
    unreachable;
  }
  fn ownPropertyKeys(self: Self) CompletionRecord([]PropertyKey) {
    if (self.vtable.ownPropertyKeys) |func| {
      return func(self);
    }
    unreachable;
  }

  fn toString(self: Self, allocator: std.mem.Allocator) ![]const u8 {
    _ = self;
    return std.fmt.allocPrint(allocator, "[object Object]", .{});
  }
};

const Binding = struct {
  identifier: []const u8,
  initialized: bool,
  mutable: bool,
  deletable: bool,
  strict: bool,
  value: ?Value,
};

// This methods are defined in 9.1.1
const EnvironmentRecord = struct {
  allocator: std.mem.Allocator,
  vtable: VTable,
  outerEnv: ?*EnvironmentRecord,
  environment: std.StringHashMap(Binding),

  const Self = @This();

  const VTable = struct {
    // Determine if an Environment Record has a binding for the String value
    // identifier. Return true if it does and false if it does not.
    hasBinding: ?*const fn (self: Self, identifier: []const u8) CompletionRecord(bool) = null,
    //  Create a new but uninitialized mutable binding in an Environment Record.
    //  The String value identifier is the text of the bound name. If the Boolean
    //  argument D is true the binding may be subsequently deleted.
    createMutableBinding: ?*const fn (self: *Self, identifier: []const u8, deletable: bool) CompletionRecord(void) = null,
    //  Create a new but uninitialized immutable binding in an Environment Record.
    //  The String value identifier is the text of the bound name. If S is true
    //  then attempts to set it after it has been initialized will always throw an
    //  exception, regardless of the strict mode setting of operations that
    //  reference that binding.
    createImmutableBinding: ?*const fn (self: *Self, identifier: []const u8, strict: bool) CompletionRecord(void) = null,
    // Set the value of an already existing but uninitialized binding in an
    // Environment Record. The String value identifier is the text of the bound
    // name. V is the value for the binding and is a value of any ECMAScript
    // language type.
    initializeBinding: ?*const fn (self: *Self, identifier: []const u8, value: Value) CompletionRecord(void) = null,
    //  Set the value of an already existing mutable binding in an Environment
    //  Record. The String value identifier is the text of the bound name. V is
    //  the value for the binding and may be a value of any ECMAScript language
    //  type. S is a Boolean flag. If S is true and the binding cannot be set
    //  throw a TypeError exception.
    setMutableBinding: ?*const fn (self: *Self, identifier: []const u8, value: Value, strict: bool) CompletionRecord(void) = null,
    // Returns the value of an already existing binding from an Environment
    // Record. The String value identifier is the text of the bound name. S is
    // used to identify references originating in strict mode code or that
    // otherwise require strict mode reference semantics. If S is true and the
    // binding does not exist throw a ReferenceError exception. If the binding
    // exists but is uninitialized a ReferenceError is thrown, regardless of the
    // value of S.
    getBindingValue: ?*const fn (self: Self, identifier: []const u8, strict: bool) CompletionRecord(Value) = null,
    //  Delete a binding from an Environment Record. The String value identifier
    //  is the text of the bound name. If a binding for N exists, remove the
    //  binding and return true. If the binding exists but cannot be removed
    //  return false. If the binding does not exist return true.
    deleteBinding: ?*const fn (self: *Self, identifier: []const u8) CompletionRecord(void) = null,
    //  Determine if an Environment Record establishes a this binding. Return true
    //  if it does and false if it does not.
    hasThisBinding: ?*const fn (self: Self) CompletionRecord(bool) = null,
    // Determine if an Environment Record establishes a super method binding.
    // Return true if it does and false if it does not. If it returns true it
    // implies that the Environment Record is a Function Environment Record,
    // although the reverse implication does not hold.
    hasSuperBinding: ?*const fn (self: Self) CompletionRecord(bool) = null,
    // If this Environment Record is associated with a with statement, return the
    // with object. Otherwise, return undefined.
    withBaseObject: ?*const fn (self: Self) CompletionRecord(Value) = null,
  };

  fn init(allocator: std.mem.Allocator, outerEnv: ?*EnvironmentRecord, vtable: VTable) Self {
    return Self{
      .allocator = allocator,
      .outerEnv = outerEnv,
      .environment = std.StringHashMap(Binding).init(allocator),
      .vtable = vtable,
    };
  }

  fn get(self: Self, name: []const u8) ?Binding {
    if (self.environment.get(name)) |value| {
      return value;
    }
    self.outerEnv.get(name);
  }

  fn put(self: Self, name: []const u8, value: Binding) std.mem.Allocator.Error!void {
    return self.environment.put(name, value);
  }

  // 9.1.1.1.1
  fn hasBinding(self: EnvironmentRecord, identifier: []const u8) CompletionRecord(bool) {
    if (self.vtable.hasBinding) |hasBindingFn| {
      return hasBindingFn(self, identifier);
    }
    return self.environment_record.get(identifier) != null;
  }

  // 9.1.1.1.2
  fn createMutableBinding(self: *EnvironmentRecord, identifier: []const u8, deletable: bool) CompletionRecord(void) {
    if (self.vtable.createMutableBinding) |createMutableBindingFn| {
      return createMutableBindingFn(self, identifier, deletable);
    }

    std.debug.assert(self.environment.get(identifier) == null);
    self.environment.put(identifier, Binding{
      .identifier = identifier,
      .initialized = false,
      .mutable = true,
      .strict = false,
      .deletable = deletable,
      .value = null,
    }) catch {
      return .throwCompletion(makeTypeError(self.allocator));
    };
    return .unused;
  }

  // 9.1.1.1.3
  fn createImmutableBinding(self: *EnvironmentRecord, identifier: []const u8, strict: bool) CompletionRecord(void) {
    if (self.vtable.createImmutableBinding) |createImmutableBindingFn| {
      return createImmutableBindingFn(self, identifier, strict);
    }

    std.debug.assert(self.environment.get(identifier) == null);
    self.environment.put(Binding{
      .identifier = identifier,
      .initialized = false,
      .mutable = false,
      .strict = strict,
      .deletable = false,
    });
    return .unused;
  }

  // 9.1.1.1.4
  fn initializeBinding(self: *EnvironmentRecord, identifier: []const u8, value: Value) CompletionRecord(void) {
    if (self.vtable.initializeBinding) |initializeBindingFn| {
      return initializeBindingFn(self, identifier, value);
    }

    var binding = self.environment.get(identifier).?;
    binding.value = value;
    binding.initialized = true;
    return .unused;
  }

  // 9.1.1.1.5
  fn setMutableBinding(self: *EnvironmentRecord, identifier: []const u8, value: Value, strict: bool) CompletionRecord(void) {
    if (self.vtable.setMutableBinding) |setMutableBindingFn| {
      return setMutableBindingFn(self, identifier, value, strict);
    }

    if (self.environment.get(identifier)) |binding| {
      if (!binding.initialized) {
        return CompletionRecord{

        };
      }
    } else {
      if (strict) {
        return .throwCompletion(makeTypeError(self.allocator));
      } else {
        _ = self.createMutableBinding(identifier, true);
        _ = self.initializeBinding(identifier, value);
        return .unused;
      }
    }
  }
  fn getBindingValue(self: EnvironmentRecord, identifier: []const u8, strict: bool) CompletionRecord(Value) {
    if (self.vtable.getBindingValue) |getBindingValueFn| {
      return getBindingValueFn(self, identifier, strict);
    }
    unreachable;
  }
  fn deleteBinding(self: *EnvironmentRecord, identifier: []const u8) CompletionRecord(void) {
    if (self.vtable.deleteBinding) |deleteBindingFn| {
      return deleteBindingFn(self, identifier);
    }
    unreachable;
  }
  fn hasThisBinding(self: EnvironmentRecord) CompletionRecord(bool) {
    if (self.vtable.hasThisBinding) |hasThisBindingFn| {
      return hasThisBindingFn(self);
    }
    unreachable;
  }
  fn hasSuperBinding(self: EnvironmentRecord) CompletionRecord(bool) {
    if (self.vtable.hasSuperBinding) |hasSuperBindingFn| {
      return hasSuperBindingFn(self);
    }
    unreachable;
  }
  fn withBaseObject(self: EnvironmentRecord) CompletionRecord(Value) {
    if (self.vtable.withBaseObject) |withBaseObjectFn| {
      return withBaseObjectFn(self);
    }
    unreachable;
  }
};

const Realm = struct {
  global_object: Object,
  global_er: GlobalEnvironmentRecord,

  allocator: std.mem.Allocator,
  object_store: std.SinglyLinkedList(Object),

  const ObjectList = std.SinglyLinkedList(Object);

  const Self = @This();

  fn init(allocator: std.mem.Allocator) !Self {
    const global_object = Object.init(allocator, null);
    var object_store = ObjectList{};
    const node = try allocator.create(ObjectList.Node);
    node.data = global_object;
    object_store.prepend(node);
    const global_er = GlobalEnvironmentRecord.init(allocator, global_object);

    // Should probably be done somewhere else
    // global_er.object_er()

    return Self{
      .global_object = global_object,
      .global_er = global_er,

      .allocator = allocator,
      .object_store = object_store,
    };
  }

  fn deinit(self: *Self) void {
    while (self.object_store.len() > 0) {
      const node = self.object_store.popFirst();
      self.allocator.free(node);
    }
  }

  // 10.1.12 OrdinaryObjectCreate ( proto [ , additionalInternalSlotsList ] ), https://tc39.es/ecma262/#sec-ordinaryobjectcreate
  fn makeObject(self: *Self, prototype: ?*Object) Object {
    // TODO additionalInternalSlotsList
    const object = Object.init(self.allocator, prototype);
    self.object_store.prepend(ObjectList.Node{ .data = object });
    return *object;
  }
};

const Error = Object;
const TypeError = Object;

fn makeTypeError(allocator: std.mem.Allocator) TypeError {
  return TypeError{
    .prototype = Error{
      .prototype = &Object.init(allocator, null),
    },
  };
}

// 6.2.4 #sec-completion-record-specification-type
fn CompletionRecord(comptime T: type) type {
  const CompletionRecordType = enum {
    normal,
    throw,
    @"return",
    @"break",
    @"continue",
  };

  return struct {
    value: union(CompletionRecordType) {
      normal: T,
      throw: Object,
      @"return": void,
      @"break": void,
      @"continue": void,
    },
    target: ?[]const u8,

    const Self = @This();

    const unused = CompletionRecord(void){
      .value = .{ .normal = undefined },
    };
    // 6.2.4.1
    pub fn normalCompletion(comptime TT: type, value: type) CompletionRecord(T) {
      return CompletionRecord(TT){
        .value = .{ .normal = value },
      };
    }
    // 6.2.4.2
    pub fn throwCompletion(err: Object) CompletionRecord(void) {
      return CompletionRecord(void){
        .value = .{ .throw = err },
      };
    }
  };
}

// This methods are defined in 9.1.1.2
const DeclarativeEnvironmentRecord = struct {
  environment_record: EnvironmentRecord,

  const Self = @This();

  fn init(allocator: std.mem.Allocator, outerEnv: ?*EnvironmentRecord) Self {
    return Self{
      .environment_record = EnvironmentRecord.init(allocator, outerEnv, .{
        // .hasBinding = hasBinding,
        // .createMutableBinding = createMutableBinding,
        // .createImmutableBinding = createImmutableBinding,
        // .initializeBinding = initializeBinding,
        // .setMutableBinding = setMutableBinding,
        // .getBindingValue = getBindingValue,
        // .deleteBinding = deleteBinding,
        // .hasThisBinding = hasThisBinding,
        // .hasSuperBinding = hasSuperBinding,
        // .withBaseObject = withBaseObject,
      }),
    };
  }
};

const ObjectEnvironmentRecord = struct {
  environment_record: EnvironmentRecord,
  binding_object: Object,

  const Self = @This();

  fn init(allocator: std.mem.Allocator, binding_object: Object, outerEnv: ?*EnvironmentRecord) Self {
    return Self{
      .environment_record = EnvironmentRecord.init(allocator, outerEnv, .{}),
      .binding_object = binding_object,
    };
  }
};

// 9.1.1.4 Global Environment Records #sec-global-environment-records
const GlobalEnvironmentRecord = struct {
  environment_record: EnvironmentRecord,
  declarative_er: DeclarativeEnvironmentRecord,
  object_er: ObjectEnvironmentRecord,

  const Self = @This();

  fn init(allocator: std.mem.Allocator, global_object: Object) Self {
    var declarative_er = DeclarativeEnvironmentRecord.init(allocator, null);
    var object_er = ObjectEnvironmentRecord.init(allocator, global_object, null);
    var global = Self{
      .environment_record = EnvironmentRecord.init(allocator, null, .{
        // .hasBinding = hasBinding,
        // .createMutableBinding = createMutableBinding,
        // .createImmutableBinding = createImmutableBinding,
        // .initializeBinding = initializeBinding,
        // .setMutableBinding = setMutableBinding,
        // .getBindingValue = getBindingValue,
        // .deleteBinding = deleteBinding,
        // .hasThisBinding = hasThisBinding,
        // .hasSuperBinding = hasSuperBinding,
        // .withBaseObject = withBaseObject,
      }),
      .declarative_er = declarative_er,
      .object_er = object_er,
    };
    declarative_er.environment_record.outerEnv = &global.environment_record;
    object_er.environment_record.outerEnv = &global.environment_record;
    return global;
  }

  // 9.1.1.1.1
  fn hasBinding(self: EnvironmentRecord, identifier: []const u8) bool {
    _ = self;
    _ = identifier;
    unreachable;
  }

  // 9.1.1.1.2
  fn createMutableBinding(self: *EnvironmentRecord, identifier: []const u8, deletable: bool) CompletionRecord {
    _ = self;
    _ = identifier;
    _ = deletable;
    unreachable;
  }

  // 9.1.1.1.3
  fn createImmutableBinding(self: *EnvironmentRecord, identifier: []const u8, strict: bool) void {
    _ = self;
    _ = identifier;
    _ = strict;
    unreachable;
  }

  // 9.1.1.1.4
  fn initializeBinding(self: *EnvironmentRecord, identifier: []const u8, value: Value) void {
    _ = self;
    _ = identifier;
    _ = value;
    unreachable;
  }

  // 9.1.1.1.5
  fn setMutableBinding(self: *EnvironmentRecord, identifier: []const u8, value: Value, strict: bool) void {
    _ = self;
    _ = identifier;
    _ = value;
    _ = strict;
    unreachable;
  }
  fn getBindingValue(self: EnvironmentRecord, identifier: []const u8, strict: bool) Value {
    _ = self;
    _ = identifier;
    _ = strict;
    unreachable;
  }
  fn deleteBinding(self: *EnvironmentRecord, identifier: []const u8) void {
    _ = self;
    _ = identifier;
    unreachable;
  }
  fn hasThisBinding(self: EnvironmentRecord, ) bool {
    _ = self;
    unreachable;
  }
  fn hasSuperBinding(self: EnvironmentRecord, ) bool {
    _ = self;
    unreachable;
  }
  fn withBaseObject(self: EnvironmentRecord, ) Value {
    _ = self;
    unreachable;
  }
  // 9.1.1.4.11
  fn getThisBinding(self: EnvironmentRecord) CompletionRecord(Object) {
    return .normalCompletion(Object, self.object_er.binding_object);
  }
};

const VM = struct {
  realm: Realm,

  const Self = @This();

  fn init(allocator: std.mem.Allocator) !Self {
    return Self{
      .realm = try .init(allocator),
    };
  }

  fn declare_variable(self: *Self, identifier: []const u8) void {
    self.realm.global_er.environment_record.createMutableBinding(identifier, true);
  }
};

pub fn hoist(parser: jam.Parser, index: jam.Ast.Node.Index, vm: *VM) void {
  const node = parser.tree.?.getNode(index);
  return switch (node.data) {
    .program => |sub_range| {
      if (sub_range) |sr| {
        for (sr.asSlice(parser.tree.?)) |i| {
          hoist(parser, i, vm);
        }
      }
    },
    .variable_declaration => |variable_declaration| {
      if (variable_declaration.kind == .@"var") {
        for (variable_declaration.declarators.asSlice(parser.tree.?)) |i| {
          hoist(parser, i, vm);
        }
      }
    },
    .variable_declarator => |variable_declarator| {
      std.log.debug("variable_declarator node {}", .{ parser.tree.?.nodes.get(@intFromEnum(variable_declarator.lhs)) });
      std.log.debug("variable_declarator {}", .{ variable_declarator });
      switch (parser.tree.?.getNode(variable_declarator.lhs).data) {
        .binding_identifier => |binding_identifier| {
          const token = parser.tree.?.getToken(binding_identifier);
          const identifier = token.toByteSlice(parser.source);
          vm.declare_variable(identifier);
        },
        else => unreachable,
      }
    },
    .function_declaration => |function| { _ = function; unreachable; },
    else => {
      std.log.debug("node.data {}", .{ node.data });
    },
  };
}

pub fn walk(tree: *const jam.Parser.Tree, index: jam.Ast.Node.Index, vm: *VM) Value {
  const node = tree.nodes.get(@intFromEnum(index));
  return switch (node.data) {
    .program => |sub_range| {
      if (sub_range) |sr| {
        for (sr.asSlice(tree)) |i| {
          return walk(tree, i, vm);
        }
      }
      unreachable;
    },
    .assignment_expr => |binaryPayload| { _ = binaryPayload; unreachable; },
    .binary_expr => |binary_payload| {
      const lhs = walk(tree, binary_payload.lhs, vm);
      const rhs = walk(tree, binary_payload.rhs, vm);
      const operator = binary_payload.getOperatorKind(tree);
      switch (operator) {
        .@"+", .@"-", .@"*", .@"/", .@"**" => {
          switch (lhs) {
            .primitive => |p| {
              switch (p) {
                .number => |lhs_number| {
                  const rhs_number = rhs.getPrimitiveAs(.number);
                  switch (operator) {
                    .@"+" => return Value{ .primitive = Value{ .number = lhs_number + rhs_number } },
                    .@"-" => return Value{ .primitive = Value{ .number = lhs_number - rhs_number } },
                    .@"*" => return Value{ .primitive = Value{ .number = lhs_number * rhs_number } },
                    .@"/" => return Value{ .primitive = Value{ .number = lhs_number / rhs_number } },
                    .@"**" => return Value{ .primitive = Value{ .number = std.math.pow(f64, lhs_number, rhs_number) } },
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
      const operand = walk(tree, unary_payload.operand, vm);
      switch (operator) {
        .@"-" => {
          switch (operand) {
            .primitive => |p| {
              switch (p) {
                .number => |number| {
                  switch (operator) {
                    .@"-" => return Value{ .primitive = Value{ .number = -number } },
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
      return Value{ .primitive = Value{ .number = number.value(tree) } };
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
    .parenthesized_expr => |node_index| return walk(tree, node_index, vm),
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
    .expression_statement => |node_index| return walk(tree, node_index, vm),
    .variable_declaration => |variable_declaration| { _ = variable_declaration; unreachable; },
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
pub fn interpret(allocator: std.mem.Allocator, parser: jam.Parser, vm: *VM) !Value {
  _ = allocator;
  hoist(parser, parser.tree.?.root, vm);
  return Value{ .@"undefined" = {} };
}

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  defer std.debug.assert(gpa.deinit() == .ok);

  var vm = VM.init(allocator);

  while (true) {
    const result = try cli.get_command(allocator, history_file);
    if (result) |command| {
      defer allocator.free(command);
      var parser = try jam.Parser.init(allocator, command, .{ .source_type = .script });
      defer parser.deinit();

      if (parser.parse()) |*ast| {
        defer @constCast(ast).deinit();
        const value = try interpret(allocator, parser, &vm);
        const pretty_string = try value.toString(allocator);
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

fn test_for_value(comptime tag: ValueTag, expr: []const u8, expected_value: GetReturnType(Value, tag)) !void {
  const allocator = std.testing.allocator;

  // var der = EnvironmentRecord.init(allocator, null);
  // var globalThis = Object{};
  var vm = VM{};

  var parser = try jam.Parser.init(allocator, expr, .{ .source_type = .script });
  defer parser.deinit();
  var ast = try parser.parse();
  defer ast.deinit();
  const value = try interpret(allocator, &ast, &vm);
  try std.testing.expectEqual(expected_value, value.getPrimitiveAs(.number));
}

test "basic tests" {
  try test_for_value(.number, "var a;", 2);
  // try test_for_value(.number, "1+1", 2);
  // try test_for_value(.number, "1-1", 0);
  // try test_for_value(.number, "3*2", 6);
  // try test_for_value(.number, "4/2", 2);
  // try test_for_value(.number, "3*(2+2)/2-1", 5);
  // try test_for_value(.number, "2**8", 256);
  // // try test_for_value(.number, "1^2", 3);
  // // try test_for_value(.number, "1^3", 2);
  // // try test_for_value(.number, "1&2", 0);
  // // try test_for_value(.number, "1|2", 3);
  // try test_for_value(.number, "-7", -7);
  // try test_for_value(.number, "let a = 42; a;", 42);
}

fn hoist_test(expr: []const u8, vm: *VM) !void {
  const allocator = std.testing.allocator;

  var parser = try jam.Parser.init(allocator, expr, .{ .source_type = .script });
  defer parser.deinit();
  var ast = try parser.parse();
  defer ast.deinit();

  hoist(parser, ast.tree.root, vm);
}


test "hoist tests" {
  std.testing.log_level = .debug;
  {
    var vm = try VM.init(std.testing.allocator);
    try hoist_test("var a;", &vm);
  }
}