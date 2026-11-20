# src/desktop_kit/glib/native.cr
module DesktopKit
  # :nodoc:
  # Conversions between Crystal values and C strings, string vectors and
  # GLists.
  module Native
    def self.string(value : String?) : UInt8*
      value ? value.to_unsafe : Pointer(UInt8).null
    end

    def self.string?(pointer : UInt8*) : String?
      String.new(pointer) unless pointer.null?
    end

    # Converts a string the callee allocated and frees it.
    def self.take_string?(pointer : UInt8*) : String?
      return if pointer.null?
      String.new(pointer).tap { C.g_free(pointer) }
    end

    # Returns a NULL-terminated vector of *values*; pass `#to_unsafe` of the
    # result and keep the result alive for the duration of the call.
    def self.strv(values : Enumerable(String)) : Array(UInt8*)
      vector = values.map(&.to_unsafe).to_a
      vector << Pointer(UInt8).null
    end

    # Copies a NULL-terminated vector the callee keeps.
    def self.strv?(pointer : UInt8**) : Array(String)
      result = [] of String
      return result if pointer.null?
      until (item = pointer.value).null?
        result << String.new(item)
        pointer += 1
      end
      result
    end

    # Copies a NULL-terminated vector and frees it with `g_strfreev`.
    def self.take_strv(pointer : UInt8**) : Array(String)
      strv?(pointer).tap { C.g_strfreev(pointer) }
    end

    def self.each(list : C::GList*, & : Void* ->) : Nil
      node = list
      until node.null?
        yield node.value.data
        node = node.value.next_
      end
    end

    # Maps a list the callee allocated and frees its nodes.
    def self.take_list(list : C::GList*, & : Void* -> T) : Array(T) forall T
      result = [] of T
      each(list) { |data| result << yield data }
      result
    ensure
      C.g_list_free(list)
    end
  end
end
