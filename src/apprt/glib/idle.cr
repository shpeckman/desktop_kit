# src/apprt/glib/idle.cr
module Apprt
  # :nodoc:
  # One-shot callbacks on the GLib main loop of the UI thread. `add` runs a
  # block once the loop is idle, `after` once an interval passed; both
  # return the source id, and `cancel` drops a source that has not run yet.
  # The block lives in `Handles` until GLib drops the source. Exceptions are
  # logged to `Apprt::Log`.
  module Idle
    private CALL = ->(data : Void*) do
      begin
        Handles.get(data, Proc(Nil)).call
      rescue ex
        Log.error(exception: ex) { "idle callback" }
      end
      C::SOURCE_REMOVE
    end

    def self.add(&block : ->) : UInt32
      C.g_idle_add_full(C::PRIORITY_DEFAULT_IDLE, CALL, Handles.retain(block), Handles::RELEASE)
    end

    def self.after(interval : Time::Span, &block : ->) : UInt32
      C.g_timeout_add_full(C::PRIORITY_DEFAULT, interval.total_milliseconds.clamp(0, UInt32::MAX).to_u32, CALL, Handles.retain(block), Handles::RELEASE)
    end

    # Removes *source*; it must not have run yet.
    def self.cancel(source : UInt32) : Nil
      C.g_source_remove(source)
    end
  end
end
