# examples/dialogs.cr
#
# A notes window whose header bar asks the user things: rename the window
# in a prompt, clear the note after a destructive confirmation, send a
# desktop notification, show a toast and open a link.
#
#   crystal run examples/dialogs.cr
#
# Dropping files on the note inserts their paths; dropped text is inserted
# as is.
require "../src/apprt"

lib LibGtk
  fun gtk_text_view_new : Void*
  fun gtk_text_view_get_buffer(view : Void*) : Void*
  fun gtk_text_view_set_left_margin(view : Void*, margin : Int32)
  fun gtk_text_view_set_top_margin(view : Void*, margin : Int32)
  fun gtk_text_buffer_set_text(buffer : Void*, text : UInt8*, length : Int32)
  fun gtk_text_buffer_insert_at_cursor(buffer : Void*, text : UInt8*, length : Int32)
  fun gtk_text_buffer_get_char_count(buffer : Void*) : Int32
end

module Dialogs
  Apprt.action Rename, "rename", scope: :window
  Apprt.action Clear, "clear", scope: :window
  Apprt.action Toast, "toast", scope: :window
  Apprt.action Notify, "notify", scope: :window

  # Icons, tooltips and actions of the header bar buttons.
  BUTTONS = [
    {"document-edit-symbolic", "Rename Window", Rename.new},
    {"edit-clear-all-symbolic", "Clear Note", Clear.new},
    {"chat-message-new-symbolic", "Show Toast", Toast.new},
    {"preferences-system-notifications-symbolic", "Send Notification", Notify.new},
    {"web-browser-symbolic", "Open crystal-lang.org", Apprt::Action::OpenUrl.new("https://crystal-lang.org")},
  ]

  # A text view that takes dropped files and text.
  class Note < Apprt::WidgetContent
    def initialize
      view = LibGtk.gtk_text_view_new
      LibGtk.gtk_text_view_set_left_margin(view, 12)
      LibGtk.gtk_text_view_set_top_margin(view, 8)
      super(Apprt::Widget.new(view))
    end

    def empty? : Bool
      LibGtk.gtk_text_buffer_get_char_count(buffer) == 0
    end

    def clear : Nil
      LibGtk.gtk_text_buffer_set_text(buffer, "", 0)
    end

    protected def on_drop(files : Array(Path)) : Bool
      insert(files.join('\n') + '\n')
    end

    protected def on_drop(text : String) : Bool
      insert(text)
    end

    private def insert(text : String) : Bool
      LibGtk.gtk_text_buffer_insert_at_cursor(buffer, text, text.bytesize)
      true
    end

    private def buffer : Void*
      LibGtk.gtk_text_view_get_buffer(widget)
    end
  end

  class App < Apprt::App
    protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
      Note.new
    end

    protected def on_startup : Nil
      self.bindings = [Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new)]
    end

    protected def on_activate : Nil
      new_window
    end

    protected def on_window(window : Apprt::Window) : Nil
      window.subtitle = "Drop files or text on the note"
      BUTTONS.each { |icon, tooltip, action| window.pack_start(action, icon, tooltip) }
    end

    protected def perform(target : Apprt::Window, action : Rename) : Bool
      target.prompt("Rename Window", "An empty name restores the default.", text: target.title, confirm: "Rename") do |name|
        target.title_override = name.presence
      end
      true
    end

    protected def perform(target : Apprt::Window, action : Clear) : Bool
      note = target.tabs.first?.try(&.surfaces.first?).try(&.content).as?(Note) || return false
      if note.empty?
        target.toast("The note is already empty")
        return true
      end
      target.confirm("Clear the Note?", "Its text cannot be restored.", confirm: "Clear", destructive: true) do |clear|
        note.clear if clear
        target.toast(clear ? "Note cleared" : "Kept the note")
      end
      true
    end

    protected def perform(target : Apprt::Window, action : Toast) : Bool
      target.toast("Toasts stack and fade after three seconds")
      true
    end

    protected def perform(target : Apprt::Window, action : Notify) : Bool
      surface = target.tabs.first?.try(&.surfaces.first?) || return false
      surface.notify("Hello from apprt", "Click to come back to this window.")
      true
    end
  end
end

exit Dialogs::App.new("org.example.Dialogs").run
