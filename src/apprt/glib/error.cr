# src/apprt/glib/error.cr
module Apprt
  # Raised when a GLib, GIO, GTK or libadwaita call reports a `GError`.
  class GLibError < Exception
    # Returns the error domain, such as `"g-io-error-quark"`.
    getter domain : String
    getter code : Int32

    def initialize(@domain : String, @code : Int32, message : String)
      super(message)
    end

    # :nodoc:
    # Converts *error* and frees it.
    def self.take(error : C::GError*) : self
      value = error.value
      new(String.new(C.g_quark_to_string(value.domain)), value.code, String.new(value.message))
    ensure
      C.g_error_free(error)
    end

    # :nodoc:
    # Yields a `GError**` out parameter and raises the error the call set.
    def self.check!(& : C::GError** -> T) : T forall T
      error = Pointer(C::GError).null
      result = yield pointerof(error)
      raise take(error) unless error.null?
      result
    end
  end
end
