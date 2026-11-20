# src/desktop_kit/content/drag.cr
module DesktopKit
  # What a drag and drop does with its data.
  @[Flags]
  enum DragAction : UInt32
    # The target copies the data.
    Copy = 1
    # The target takes the data; the source deletes it.
    Move = 2
    # The target links to the data.
    Link = 4

    # :nodoc:
    def self.from_gdk(action : C::GdkDragAction) : self
      new(action.value & All.value)
    end

    # :nodoc:
    def to_gdk : C::GdkDragAction
      C::GdkDragAction.new(value)
    end
  end

  # A drag over a `Canvas`, from this application or another one.
  #
  # The canvas hands the same drop to every hook of one drag. Once
  # `Canvas#on_drop` took it, read its data with `#read` and end it with
  # `#finish`.
  class Drop < Wrapper
    private READ = ->(drop : Void*, result : Void*, data : Void*) do
      block = Handles.get(data, Proc(Bytes?, Nil))
      Handles.release(data)
      stream = begin
        GLibError.check! { |error| C.gdk_drop_read_finish(drop, result, Pointer(UInt8*).null, error) }
      rescue ex : GLibError
        Log.warn { "drop read: #{ex.message}" }
        Pointer(Void).null
      end
      if stream.null?
        begin
          block.call(nil)
        rescue ex
          Log.error(exception: ex) { "drop read" }
        end
      else
        Stream.read_all(stream, "drop read", &block)
      end
      nil
    end

    @finished = false

    # Returns the MIME types the drag offers, in the order its source listed
    # them.
    def mime_types : Array(String)
      types = C.gdk_content_formats_get_mime_types(C.gdk_drop_get_formats(self), out count)
      Array(String).new(count) { |index| String.new(types[index]) }
    end

    # Returns the actions the drag's source allows.
    def actions : DragAction
      DragAction.from_gdk(C.gdk_drop_get_actions(self))
    end

    # Whether the drag started in this application.
    def local? : Bool
      !C.gdk_drop_get_drag(self).null?
    end

    # Reads the data of *mime_type* and yields it, or `nil` when the drag
    # does not offer it or reading fails. The block runs later on the GTK
    # thread. Read before `#finish`.
    def read(mime_type : String, &block : Bytes? ->) : Nil
      types = Native.strv({mime_type})
      C.gdk_drop_read_async(self, types.to_unsafe, C::PRIORITY_DEFAULT, nil, READ, Handles.retain(block))
    end

    # Ends the drop with *action*, the one performed; `DragAction::None`
    # reports a failure. Does nothing after the first call.
    def finish(action : DragAction) : Nil
      return if @finished
      @finished = true
      C.gdk_drop_finish(self, action.to_gdk)
    end
  end

  # A drag that a `Canvas` started with `Canvas#drag`.
  #
  # The data is produced on request: each `Request` asks for one MIME type
  # once a target wants it. `Canvas#on_drag_end` reports the outcome.
  class Drag < Wrapper
    # An image shown under the pointer during a drag: *width* × *height*
    # pixels of straight (not premultiplied) RGBA, 8 bits per channel, row
    # by row, with the pointer at *hot_x*, *hot_y*.
    record Icon, width : Int32, height : Int32, pixels : Bytes, hot_x : Int32 = 0, hot_y : Int32 = 0

    # A target's request for the data of one MIME type.
    #
    # Answer every request once, with `#reply` or `#fail`, on the GTK
    # thread; the target waits until then.
    class Request
      getter mime_type : String

      @done = false

      protected def initialize(@mime_type : String, @stream : Void*, @task : Void*)
      end

      # Sends *data* to the target.
      def reply(data : Bytes) : Nil
        return if done!
        DragContent.write(@stream, @task, data)
      end

      # Tells the target that the data is unavailable.
      def fail(message : String = "no data") : Nil
        # A local (same-process) read of a failed request yields empty
        # data, not an error.
        return if done!
        DragContent.fail(@stream, @task, message)
      end

      private def done! : Bool
        UIThread.assert!
        done = @done
        @done = true
        done
      end
    end

    getter mime_types : Array(String)

    @ended = false

    protected def initialize(pointer : Void*, @mime_types : Array(String))
      super(pointer)
    end

    # Returns the action the target under the pointer would perform, or
    # `DragAction::None`.
    def action : DragAction
      DragAction.from_gdk(C.gdk_drag_get_selected_action(self))
    end

    # Ends the drag once; returns whether this call ended it.
    protected def end! : Bool
      ended = @ended
      @ended = true
      !ended
    end
  end

  # :nodoc:
  # The lazy content of a `Drag`: a `GdkContentProvider` subclass whose
  # `ref_formats`, `write_mime_type_async` and `write_mime_type_finish`
  # vfuncs answer from a `Source` kept in the provider's data. The vfuncs
  # sit right after the `GObjectClass` fields of `GdkContentProviderClass`
  # (content_changed, attach_clipboard, detach_clipboard, ref_formats,
  # ref_storable_formats, write_mime_type_async, write_mime_type_finish,
  # get_value); the class layout is public ABI.
  module DragContent
    # The MIME types and the request handler of one drag.
    record Source, mime_types : Array(String), handler : Proc(Drag::Request, Nil)

    private KEY = "desktop-kit-drag-content"

    private SLOT_REF_FORMATS = 3
    private SLOT_WRITE       = 5
    private SLOT_FINISH      = 6

    private REF_FORMATS = ->(provider : Void*) do
      types = Native.strv(DragContent.source(provider).mime_types)
      C.gdk_content_formats_new(types.to_unsafe, (types.size - 1).to_u32)
    end

    private WRITE = ->(provider : Void*, mime_type : UInt8*, stream : Void*, _priority : Int32, cancellable : Void*, callback : Void*, data : Void*) do
      # GIO's callback arrives as a bare function pointer.
      ready = C::GAsyncReadyCallback.new(callback, Pointer(Void).null)
      task = C.g_task_new(provider, cancellable, ready, data)
      request = Drag::Request.new(String.new(mime_type), C.g_object_ref(stream), task)
      begin
        DragContent.source(provider).handler.call(request)
      rescue ex
        Log.error(exception: ex) { "drag request" }
        request.fail(ex.message || "drag request failed")
      end
      nil
    end

    private FINISH = ->(_provider : Void*, result : Void*, error : C::GError**) do
      C.g_task_propagate_boolean(result, error)
    end

    private CLASS_INIT = ->(klass : Void*, _data : Void*) do
      C.g_type_query(C.g_object_get_type, out query)
      slots = (klass.as(UInt8*) + query.class_size).as(Void**)
      slots[SLOT_REF_FORMATS] = REF_FORMATS.pointer
      slots[SLOT_WRITE] = WRITE.pointer
      slots[SLOT_FINISH] = FINISH.pointer
      nil
    end

    private WRITTEN = ->(stream : Void*, result : Void*, data : Void*) do
      task, _data = Handles.get(data, Tuple(Void*, Bytes))
      Handles.release(data)
      begin
        GLibError.check! { |error| C.g_output_stream_write_all_finish(stream, result, nil, error) }
        C.g_task_return_boolean(task, 1)
      rescue ex : GLibError
        Log.warn { "drag write: #{ex.message}" }
        C.g_task_return_error(task, C.g_error_new_literal(C.g_quark_from_string("desktop-kit-drag"), 0, ex.message || "write failed"))
      ensure
        C.g_object_unref(task)
        C.g_object_unref(stream)
      end
      nil
    end

    @@type = 0_u64

    # Returns a new provider of *source*; the caller owns it.
    def self.new(source : Source) : Void*
      # Source lives on the provider, not the `Drag`: there it was never
      # collected.
      provider = C.g_object_new_with_properties(type, 0, nil, nil)
      C.g_object_set_data_full(provider, KEY, Handles.retain(source), Handles::RELEASE)
      provider
    end

    protected def self.source(provider : Void*) : Source
      Handles.get(C.g_object_get_data(provider, KEY), Source)
    end

    protected def self.write(stream : Void*, task : Void*, data : Bytes) : Nil
      held = Handles.retain({task, data})
      C.g_output_stream_write_all_async(stream, data.to_unsafe.as(Void*), data.size, C::PRIORITY_DEFAULT, nil, WRITTEN, held)
    end

    protected def self.fail(stream : Void*, task : Void*, message : String) : Nil
      C.g_task_return_error(task, C.g_error_new_literal(C.g_quark_from_string("desktop-kit-drag"), 0, message))
      C.g_object_unref(task)
      C.g_object_unref(stream)
    end

    private def self.type : UInt64
      return @@type unless @@type == 0
      parent = C.gdk_content_provider_get_type
      C.g_type_query(parent, out query)
      @@type = C.g_type_register_static_simple(parent, "DesktopKitDragContent", query.class_size, CLASS_INIT,
        query.instance_size, nil, C::GTypeFlags::Final)
    end
  end
end
