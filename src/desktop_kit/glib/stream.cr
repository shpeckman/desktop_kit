# src/desktop_kit/glib/stream.cr
module DesktopKit
  # :nodoc:
  # Reads GIO input streams to their end on the main loop. GDK hands
  # clipboard and drop data over as streams; `read_all` splices one into a
  # memory stream and yields the bytes, or `nil` when reading fails (logged
  # as a warning under *what*).
  module Stream
    private record Read, what : String, block : Proc(Bytes?, Nil)

    private SPLICED = ->(target : Void*, result : Void*, data : Void*) do
      read = Handles.get(data, Read)
      Handles.release(data)
      bytes = begin
        GLibError.check! { |error| C.g_output_stream_splice_finish(target, result, error) }
        Stream.take_bytes(C.g_memory_output_stream_steal_as_bytes(target))
      rescue ex : GLibError
        Log.warn { "#{read.what}: #{ex.message}" }
        nil
      ensure
        C.g_object_unref(target)
      end
      Stream.deliver(read, bytes)
      nil
    end

    # Reads *stream* to its end, closes it, drops the reference the caller
    # passed and yields the bytes on the GTK thread.
    def self.read_all(stream : Void*, what : String, &block : Bytes? ->) : Nil
      target = C.g_memory_output_stream_new_resizable
      flags = C::GOutputStreamSpliceFlags::CloseSource | C::GOutputStreamSpliceFlags::CloseTarget
      C.g_output_stream_splice_async(target, stream, flags, C::PRIORITY_DEFAULT, nil, SPLICED, Handles.retain(Read.new(what, block)))
      C.g_object_unref(stream)
    end

    # Copies *bytes* (a `GBytes`) and drops it.
    def self.take_bytes(bytes : Void*) : Bytes
      data = C.g_bytes_get_data(bytes, out size)
      Bytes.new(size).tap { |copy| copy.copy_from(data.as(UInt8*), size) unless size == 0 }
    ensure
      C.g_bytes_unref(bytes)
    end

    # Returns a new `GBytes` holding a copy of *data*; the caller owns it.
    def self.bytes(data : Bytes) : Void*
      C.g_bytes_new(data.to_unsafe.as(Void*), data.size)
    end

    protected def self.deliver(read : Read, bytes : Bytes?) : Nil
      read.block.call(bytes)
    rescue ex
      Log.error(exception: ex) { read.what }
    end
  end
end
