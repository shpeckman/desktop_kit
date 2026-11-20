# src/desktop_kit/glib/handles.cr
require "sync/exclusive"

module DesktopKit
  # :nodoc:
  # Keeps Crystal values alive while C code holds a pointer to them: GC does
  # not scan memory GLib allocates. `retain` returns the user-data pointer for
  # a C callback; GLib hands it back to `RELEASE` or `RELEASE_CLOSURE` when it
  # drops the callback. Never call into Handles from a finalizer: GC runs them
  # inside allocations, possibly while the lock is held.
  module Handles
    private abstract class Handle
    end

    private class Holder(T) < Handle
      getter value : T

      def initialize(@value : T)
      end
    end

    @@live = Sync::Exclusive(Hash(Void*, Handle)).new({} of Void* => Handle)

    RELEASE         = ->(data : Void*) { Handles.release(data) }
    RELEASE_CLOSURE = ->(data : Void*, _closure : Void*) { Handles.release(data) }

    def self.retain(value : T) : Void* forall T
      holder = Holder(T).new(value)
      pointer = holder.as(Void*)
      @@live.lock { |live| live[pointer] = holder }
      pointer
    end

    # Returns the value behind *pointer*; *type* must be the type it was
    # retained with.
    def self.get(pointer : Void*, type : T.class) : T forall T
      pointer.as(Holder(T)).value
    end

    def self.release(pointer : Void*) : Nil
      @@live.lock(&.delete(pointer))
    end

    def self.size : Int32
      @@live.lock(&.size)
    end
  end
end
