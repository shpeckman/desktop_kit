# src/apprt/clipboard.cr
module Apprt
  # The desktop's clipboards. Use them on the GTK thread only.
  #
  # ```
  # Apprt::Clipboard.write("hello")
  # Apprt::Clipboard.read { |text| puts text }
  # ```
  module Clipboard
    enum Kind
      # The clipboard copy and paste use.
      Standard
      # The primary selection: the text last selected, pasted by middle-click.
      Primary
    end

    private READ = ->(clipboard : Void*, result : Void*, data : Void*) do
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

    # Puts *text* on the clipboard *kind*.
    def self.write(text : String, kind : Kind = :standard) : Nil
      C.gdk_clipboard_set_text(clipboard(kind), text)
    end

    # Reads the text on the clipboard *kind* and yields it, or `nil` when the
    # clipboard holds no text. The block runs later on the GTK thread.
    def self.read(kind : Kind = :standard, &block : String? ->) : Nil
      C.gdk_clipboard_read_text_async(clipboard(kind), nil, READ, Handles.retain(block))
    end

    private def self.clipboard(kind : Kind) : Void*
      UIThread.assert!
      display = C.gdk_display_get_default
      raise RuntimeError.new("no display") if display.null?
      kind.primary? ? C.gdk_display_get_primary_clipboard(display) : C.gdk_display_get_clipboard(display)
    end
  end
end
