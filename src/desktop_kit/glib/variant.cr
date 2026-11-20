# src/desktop_kit/glib/variant.cr
module DesktopKit
  # An immutable GLib `GVariant`: the value type of action parameters, DBus
  # messages and portal options.
  #
  # Crystal types map to GVariant types by their static type:
  #
  # | Crystal                     | GVariant |
  # |-----------------------------|----------|
  # | `Bool`                      | `b`      |
  # | `Int32` `UInt32`            | `i` `u`  |
  # | `Int64` `UInt64`            | `x` `t`  |
  # | `Float64`                   | `d`      |
  # | `String`                    | `s`      |
  # | `Variant::ObjectPath`       | `o`      |
  # | enum (not `@[Flags]`)       | `s`, the member name in snake case |
  # | `Variant`                   | `v`      |
  # | `T?`                        | `mT`     |
  # | `Array(T)`                  | `aT`     |
  # | `Hash(K, V)`                | `a{KV}`  |
  # | `Tuple(T, U, ...)`          | `(TU...)`|
  #
  # ```
  # options = DesktopKit::Variant.new({"modal" => DesktopKit::Variant.new(true)})
  # options.type_string                # => "a{sv}"
  # options["modal"]?.try(&.get(Bool)) # => true
  # ```
  #
  # Variants are safe to share between threads.
  class Variant < Wrapper
    boxed g_variant_ref, g_variant_unref

    # A DBus object path, the GVariant type `o`.
    record ObjectPath, path : String do
      def to_s(io : IO) : Nil
        io << path
      end
    end

    # Returns a variant holding *value*; its GVariant type follows the static
    # type of *value*.
    def self.new(value : T) : self forall T
      take(C.g_variant_ref_sink(build(value, T)))
    end

    # Parses *text* in the GVariant text format (`"(1, 'a')"`); *type* fixes
    # the expected type string. Raises `GLibError` on a syntax or type error.
    def self.parse(text : String, type : String? = nil) : self
      raw = with_type(type) do |variant_type|
        GLibError.check! { |error| C.g_variant_parse(variant_type, text, Pointer(UInt8).null, Pointer(UInt8*).null, error) }
      end
      take(raw)
    end

    # Returns the GVariant type string of the Crystal type *type*
    # (`Variant.signature(Array(String))` is `"as"`).
    def self.signature(type : T.class) : String forall T
      {% if T == Bool %}
        "b"
      {% elsif T == Int32 %}
        "i"
      {% elsif T == UInt32 %}
        "u"
      {% elsif T == Int64 %}
        "x"
      {% elsif T == UInt64 %}
        "t"
      {% elsif T == Float64 %}
        "d"
      {% elsif T == String %}
        "s"
      {% elsif T == ObjectPath %}
        "o"
      {% elsif T == Variant %}
        "v"
      {% elsif T < ::Enum %}
        {% raise "Variant: flags enum #{T} has no GVariant type" if T.annotation(Flags) %}
        "s"
      {% elsif T.nilable? && T != Nil %}
        {% inner = T.union_types.reject { |member| member == Nil } %}
        {% raise "Variant: union #{T} has no GVariant type" if inner.size != 1 %}
        "m" + signature({{ inner.first }})
      {% elsif T < Array %}
        "a" + signature({{ T.type_vars[0] }})
      {% elsif T < Hash %}
        "a{" + signature({{ T.type_vars[0] }}) + signature({{ T.type_vars[1] }}) + "}"
      {% elsif T < Tuple %}
        String.build do |io|
          io << '('
          {% for member in T.type_vars %}
            io << signature({{ member }})
          {% end %}
          io << ')'
        end
      {% else %}
        {% raise "Variant: #{T} has no GVariant type" %}
      {% end %}
    end

    # Returns the GVariant type string, such as `"a{sv}"`.
    def type_string : String
      String.new(C.g_variant_get_type_string(self))
    end

    # Returns `true` when the variant's type is the GVariant type of *type*.
    def is?(type : T.class) : Bool forall T
      Variant.with_type(Variant.signature(T)) { |variant_type| C.g_variant_is_of_type(self, variant_type) != 0 }
    end

    # Returns the value as a *type*; raises `TypeCastError` when the variant
    # has another GVariant type and `ArgumentError` for an unknown enum member.
    def get(type : T.class) : T forall T
      raise TypeCastError.new("cast from Variant(#{type_string}) to #{T} failed") unless is?(T)
      Variant.read(to_unsafe, T)
    end

    # Returns the number of children of a container (array, dictionary,
    # tuple, maybe).
    def size : Int32
      C.g_variant_n_children(self).to_i32
    end

    # Returns the child at *index* of a container.
    def [](index : Int) : Variant
      raise IndexError.new unless 0 <= index < size
      Variant.take(C.g_variant_get_child_value(self, index))
    end

    # Returns the value under *key* in a dictionary with string keys
    # (`a{sv}`, `a{ss}`), unboxing `v` values, or `nil`.
    def []?(key : String) : Variant?
      Variant.take?(C.g_variant_lookup_value(self, key, Pointer(Void).null))
    end

    def ==(other : Variant) : Bool
      C.g_variant_equal(self, other) != 0
    end

    def hash(hasher)
      # g_variant_hash takes basic types only; equal variants print alike.
      hasher = type_string.hash(hasher)
      to_s.hash(hasher)
    end

    # Writes the GVariant text format (`[1, 2]`).
    def to_s(io : IO) : Nil
      io << Native.take_string?(C.g_variant_print(self, 0))
    end

    def inspect(io : IO) : Nil
      io << "Variant(" << type_string << ' '
      to_s(io)
      io << ')'
    end

    # Returns a new floating GVariant holding *value* as the GVariant type of
    # *type*.
    protected def self.build(value, type : T.class) : Void* forall T
      {% if T == Bool %}
        C.g_variant_new_boolean(value ? 1 : 0)
      {% elsif T == Int32 %}
        C.g_variant_new_int32(value)
      {% elsif T == UInt32 %}
        C.g_variant_new_uint32(value)
      {% elsif T == Int64 %}
        C.g_variant_new_int64(value)
      {% elsif T == UInt64 %}
        C.g_variant_new_uint64(value)
      {% elsif T == Float64 %}
        C.g_variant_new_double(value)
      {% elsif T == String %}
        C.g_variant_new_string(value)
      {% elsif T == ObjectPath %}
        C.g_variant_new_object_path(value.path)
      {% elsif T == Variant %}
        C.g_variant_new_variant(value)
      {% elsif T < ::Enum %}
        {% raise "Variant: flags enum #{T} has no GVariant type" if T.annotation(Flags) %}
        C.g_variant_new_string(value.to_s.underscore)
      {% elsif T.nilable? && T != Nil %}
        {% inner = T.union_types.reject { |member| member == Nil }.first %}
        with_type(signature({{ inner }})) do |child_type|
          C.g_variant_new_maybe(child_type, value.nil? ? Pointer(Void).null : build(value, {{ inner }}))
        end
      {% elsif T == Array(String) %}
        C.g_variant_new_strv(Native.strv(value), value.size)
      {% elsif T < Array %}
        children = value.map { |child| build(child, {{ T.type_vars[0] }}) }
        with_type(signature({{ T.type_vars[0] }})) do |child_type|
          C.g_variant_new_array(child_type, children, children.size)
        end
      {% elsif T < Hash %}
        entries = value.map do |key, child|
          C.g_variant_new_dict_entry(build(key, {{ T.type_vars[0] }}), build(child, {{ T.type_vars[1] }}))
        end
        with_type("{#{signature({{ T.type_vars[0] }})}#{signature({{ T.type_vars[1] }})}}") do |entry_type|
          C.g_variant_new_array(entry_type, entries, entries.size)
        end
      {% elsif T < Tuple %}
        children = StaticArray(Void*, {{ T.type_vars.size }}).new(Pointer(Void).null)
        {% for member, index in T.type_vars %}
          children[{{ index }}] = build(value[{{ index }}], {{ member }})
        {% end %}
        C.g_variant_new_tuple(children, {{ T.type_vars.size }})
      {% else %}
        {% raise "Variant: #{T} has no GVariant type" %}
      {% end %}
    end

    # Converts the borrowed *raw* GVariant, already of the GVariant type of
    # *type*.
    protected def self.read(raw : Void*, type : T.class) : T forall T
      {% if T == Bool %}
        C.g_variant_get_boolean(raw) != 0
      {% elsif T == Int32 %}
        C.g_variant_get_int32(raw)
      {% elsif T == UInt32 %}
        C.g_variant_get_uint32(raw)
      {% elsif T == Int64 %}
        C.g_variant_get_int64(raw)
      {% elsif T == UInt64 %}
        C.g_variant_get_uint64(raw)
      {% elsif T == Float64 %}
        C.g_variant_get_double(raw)
      {% elsif T == String %}
        String.new(C.g_variant_get_string(raw, Pointer(LibC::SizeT).null))
      {% elsif T == ObjectPath %}
        ObjectPath.new(String.new(C.g_variant_get_string(raw, Pointer(LibC::SizeT).null)))
      {% elsif T == Variant %}
        take(C.g_variant_get_variant(raw))
      {% elsif T < ::Enum %}
        T.parse(String.new(C.g_variant_get_string(raw, Pointer(LibC::SizeT).null)))
      {% elsif T.nilable? && T != Nil %}
        {% inner = T.union_types.reject { |member| member == Nil }.first %}
        child = C.g_variant_get_maybe(raw)
        return nil if child.null?
        begin
          read(child, {{ inner }})
        ensure
          C.g_variant_unref(child)
        end
      {% elsif T == Array(String) %}
        vector = C.g_variant_get_strv(raw, Pointer(LibC::SizeT).null)
        begin
          Native.strv?(vector)
        ensure
          C.g_free(vector)
        end
      {% elsif T < Array %}
        Array({{ T.type_vars[0] }}).new(C.g_variant_n_children(raw)) do |index|
          child(raw, index) { |child| read(child, {{ T.type_vars[0] }}) }
        end
      {% elsif T < Hash %}
        count = C.g_variant_n_children(raw)
        result = Hash({{ T.type_vars[0] }}, {{ T.type_vars[1] }}).new(initial_capacity: count)
        count.times do |index|
          child(raw, index) do |entry|
            key = child(entry, 0) { |child| read(child, {{ T.type_vars[0] }}) }
            result[key] = child(entry, 1) { |child| read(child, {{ T.type_vars[1] }}) }
          end
        end
        result
      {% elsif T < Tuple %}
        {
          {% for member, index in T.type_vars %}
            child(raw, {{ index }}) { |child| read(child, {{ member }}) },
          {% end %}
        }
      {% else %}
        {% raise "Variant: #{T} has no GVariant type" %}
      {% end %}
    end

    private def self.child(raw : Void*, index : Int, & : Void* -> T) : T forall T
      child = C.g_variant_get_child_value(raw, index)
      begin
        yield child
      ensure
        C.g_variant_unref(child)
      end
    end

    # Yields a `GVariantType*` for *type*.
    protected def self.with_type(type : String, & : Void* -> T) : T forall T
      variant_type = C.g_variant_type_new(type)
      begin
        yield variant_type
      ensure
        C.g_variant_type_free(variant_type)
      end
    end

    # :ditto:
    protected def self.with_type(type : Nil, & : Void* -> T) : T forall T
      yield Pointer(Void).null
    end
  end
end
