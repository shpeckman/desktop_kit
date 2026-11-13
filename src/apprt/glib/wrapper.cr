# src/apprt/glib/wrapper.cr
module Apprt
  # :nodoc:
  # Base of the classes that own one reference to a GObject or to a
  # ref-counted boxed value.
  #
  # Objects drop their reference on the GLib main loop: finalizers run on any
  # thread, and disposing an object can emit signals into Crystal code. Boxed
  # types (`boxed`) have no thread affinity and no handlers, so their
  # finalizer unrefs directly. Widgets are never wrapped; see `Widget`.
  abstract class Wrapper
    getter to_unsafe : Void*

    private UNREF_LATER = ->(object : Void*) { C.g_object_unref(object); C::SOURCE_REMOVE }

    protected def initialize(@to_unsafe : Void*)
    end

    # Adopts the reference the caller owns (transfer full).
    def self.take(pointer : Void*) : self
      raise ArgumentError.new("#{self}.take: null pointer") if pointer.null?
      adopt(pointer)
    end

    def self.take?(pointer : Void*) : self?
      adopt(pointer) unless pointer.null?
    end

    # Adds a reference to a pointer the caller borrows (transfer none).
    def self.from_raw(pointer : Void*) : self
      raise ArgumentError.new("#{self}.from_raw: null pointer") if pointer.null?
      adopt(c_ref(pointer))
    end

    def self.from_raw?(pointer : Void*) : self?
      adopt(c_ref(pointer)) unless pointer.null?
    end

    # Builds the instance without `new`, which subclasses may overload with
    # their own constructors.
    private def self.adopt(pointer : Void*) : self
      instance = allocate
      instance.initialize(pointer)
      GC.add_finalizer(instance)
      instance
    end

    protected def self.c_ref(pointer : Void*) : Void*
      C.g_object_ref(pointer)
    end

    protected def self.c_release(pointer : Void*) : Nil
      C.g_idle_add_full(C::PRIORITY_DEFAULT_IDLE, UNREF_LATER, pointer, nil)
    end

    def finalize
      self.class.c_release(@to_unsafe)
    end

    def ==(other : Wrapper) : Bool
      to_unsafe == other.to_unsafe
    end

    def hash(hasher)
      to_unsafe.address.hash(hasher)
    end

    # Declares a boxed type with the *ref* and *unref* functions of `Apprt::C`.
    macro boxed(ref, unref)
      protected def self.c_ref(pointer : Void*) : Void*
        C.{{ ref.id }}(pointer)
      end

      protected def self.c_release(pointer : Void*) : Nil
        C.{{ unref.id }}(pointer)
      end
    end
  end
end
