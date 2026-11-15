# src/apprt/content/clipboard.cr
module Apprt
  # The desktop's clipboards. Use them on the GTK thread only.
  #
  # Text goes through `.write(text)` and `.read`; other data through
  # `.write(items)`, `.offered` and `.read(mime_type)`, by MIME type.
  #
  # ```
  # Apprt::Clipboard.write("hello")
  # Apprt::Clipboard.read { |text| puts text }
  # Apprt::Clipboard.write([{"text/html", "<b>hi</b>".to_slice}, {"text/plain;charset=utf-8", "hi".to_slice}])
  # Apprt::Clipboard.read("text/html") { |data| puts String.new(data) if data }
  # ```
  module Clipboard
    enum Kind
      # The clipboard copy and paste use.
      Standard
      # The primary selection: the text last selected, pasted by middle-click.
      Primary
    end

    # What `Surface#confirm_clipboard` asks the user to allow.
    enum Request
      # Pasting text that looks like it runs commands.
      Paste
      # The content reading the clipboard.
      Read
      # The content writing to the clipboard.
      Write
    end

    private READ_TEXT = ->(clipboard : Void*, result : Void*, data : Void*) do
      block = Handles.get(data, Proc(String?, Nil))
      Handles.release(data)
      begin
        text = begin
          Native.take_string?(GLibError.check! { |error| C.gdk_clipboard_read_text_finish(clipboard, result, error) })
        rescue ex : GLibError
          Log.warn { "clipboard read: #{ex.message}" }
          nil
        end
        block.call(text)
      rescue ex
        Log.error(exception: ex) { "clipboard read" }
      end
      nil
    end

    private READ = ->(clipboard : Void*, result : Void*, data : Void*) do
      block = Handles.get(data, Proc(Bytes?, Nil))
      Handles.release(data)
      stream = begin
        GLibError.check! { |error| C.gdk_clipboard_read_finish(clipboard, result, Pointer(UInt8*).null, error) }
      rescue ex : GLibError
        Log.warn { "clipboard read: #{ex.message}" }
        Pointer(Void).null
      end
      if stream.null?
        begin
          block.call(nil)
        rescue ex
          Log.error(exception: ex) { "clipboard read" }
        end
      else
        Stream.read_all(stream, "clipboard read", &block)
      end
      nil
    end

    # The items this application put on each clipboard, by `Kind#value`.
    @@items = [nil, nil] of Array({String, Bytes})?

    # Puts *text* on the clipboard *kind*.
    def self.write(text : String, kind : Kind = :standard) : Nil
      C.gdk_clipboard_set_text(clipboard(kind), text)
      @@items[kind.value] = nil
    end

    # Puts *items*, MIME types and their data, on the clipboard *kind*; a
    # reader that asks for several gets the first it names. Empty *items*
    # clear the clipboard. Raises `ArgumentError` when a MIME type repeats.
    def self.write(items : Enumerable({String, Bytes}), kind : Kind = :standard) : Nil
      board = clipboard(kind)
      list = items.to_a
      raise ArgumentError.new("repeated MIME type") unless list.uniq(&.[0]).size == list.size
      if list.empty?
        C.gdk_clipboard_set_content(board, nil)
        @@items[kind.value] = nil
        return
      end
      providers = list.map do |(mime, data)|
        bytes = Stream.bytes(data)
        C.gdk_content_provider_new_for_bytes(mime, bytes).tap { C.g_bytes_unref(bytes) }
      end
      union = C.gdk_content_provider_new_union(providers.to_unsafe, providers.size)
      C.gdk_clipboard_set_content(board, union)
      C.g_object_unref(union)
      @@items[kind.value] = list.map { |(mime, data)| {mime, data.dup} }
    end

    # Returns the items this application last put on the clipboard *kind*
    # with `.write(items)`, while it still holds them; `nil` once another
    # application or `.write(text)` replaced them.
    def self.items(kind : Kind = :standard) : Array({String, Bytes})?
      board = clipboard(kind)
      return @@items[kind.value] = nil if C.gdk_clipboard_is_local(board) == 0
      @@items[kind.value]
    end

    # Returns the MIME types the clipboard *kind* offers, in the order its
    # owner listed them.
    def self.offered(kind : Kind = :standard) : Array(String)
      formats = C.gdk_clipboard_get_formats(clipboard(kind))
      types = C.gdk_content_formats_get_mime_types(formats, out count)
      Array(String).new(count) { |index| String.new(types[index]) }
    end

    # Reads the text on the clipboard *kind* and yields it, or `nil` when the
    # clipboard holds no text. The block runs later on the GTK thread.
    def self.read(kind : Kind = :standard, &block : String? ->) : Nil
      C.gdk_clipboard_read_text_async(clipboard(kind), nil, READ_TEXT, Handles.retain(block))
    end

    # Reads the data of *mime_type* on the clipboard *kind* and yields it,
    # or `nil` when the clipboard does not offer it. The block runs later on
    # the GTK thread.
    def self.read(mime_type : String, kind : Kind = :standard, &block : Bytes? ->) : Nil
      types = Native.strv({mime_type})
      C.gdk_clipboard_read_async(clipboard(kind), types.to_unsafe, C::PRIORITY_DEFAULT, nil, READ, Handles.retain(block))
    end

    private def self.clipboard(kind : Kind) : Void*
      UIThread.assert!
      display = C.gdk_display_get_default
      raise RuntimeError.new("no display") if display.null?
      kind.primary? ? C.gdk_display_get_primary_clipboard(display) : C.gdk_display_get_clipboard(display)
    end
  end
end
