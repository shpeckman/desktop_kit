# src/desktop_kit/ui/dialogs.cr
module DesktopKit
  # :nodoc:
  # Libadwaita alert dialogs. A dialog answers once through
  # `adw_alert_dialog_choose`; the block waits in `Handles` until then.
  # Exceptions raised by the block are logged.
  module Dialogs
    # What a close confirmation is about.
    enum Close
      App
      Windows
      Window
      Tab
      Split

      def heading : String
        case self
        in .app?     then DesktopKit.tr("Quit?")
        in .windows? then DesktopKit.tr("Close All Windows?")
        in .window?  then DesktopKit.tr("Close Window?")
        in .tab?     then DesktopKit.tr("Close Tab?")
        in .split?   then DesktopKit.tr("Close Split?")
        end
      end

      def body : String
        case self
        in .app?, .windows? then DesktopKit.tr("Unsaved work will be lost.")
        in .window?         then DesktopKit.tr("Unsaved work in this window will be lost.")
        in .tab?            then DesktopKit.tr("Unsaved work in this tab will be lost.")
        in .split?          then DesktopKit.tr("Unsaved work in this split will be lost.")
        end
      end

      def verb : String
        app? ? DesktopKit.tr("Quit") : DesktopKit.tr("Close")
      end
    end

    # Returns the heading and body of the clipboard confirmation for
    # *request*.
    private def self.clipboard_texts(request : Clipboard::Request) : {String, String}
      case request
      in .paste?
        {DesktopKit.tr("Warning: Potentially Unsafe Paste"),
         DesktopKit.tr("Pasting this text may be dangerous as it looks like some commands may be executed.")}
      in .read?
        {DesktopKit.tr("Authorize Clipboard Access"),
         DesktopKit.tr("An application is attempting to read from the clipboard. The current clipboard contents are shown below.")}
      in .write?
        {DesktopKit.tr("Authorize Clipboard Access"),
         DesktopKit.tr("An application is attempting to write to the clipboard. The text it would copy is shown below.")}
      end
    end

    private CHOSEN = ->(dialog : Void*, result : Void*, data : Void*) do
      block = Handles.get(data, Proc(String, Nil))
      Handles.release(data)
      begin
        block.call(Native.string?(C.adw_alert_dialog_choose_finish(dialog, result)) || "")
      rescue ex
        Log.error(exception: ex) { "dialog response" }
      end
      nil
    end

    # Asks *heading* and *body* over the window of *parent* and yields
    # whether the user picked *confirm* over *cancel*. A *destructive*
    # confirmation is shown in red and is not the default.
    def self.confirm(parent : Widget, heading : String, body : String?, confirm : String, cancel : String,
                     destructive : Bool, &done : Bool ->) : Nil
      dialog = alert(heading, body, confirm, cancel, destructive)
      choose(dialog, parent) { |response| done.call(response == "ok") }
    end

    # Asks whether to allow *request* with the clipboard *text* it concerns
    # and yields `true` when the user allows it.
    def self.confirm_clipboard(parent : Widget, request : Clipboard::Request, text : String, &done : Bool ->) : Nil
      heading, body = clipboard_texts(request)
      dialog = alert(heading, body, DesktopKit.tr("Allow"), DesktopKit.tr("Deny"), destructive: true)
      C.adw_alert_dialog_set_extra_child(dialog, text_view(text, 500, 200)[0])
      choose(dialog, parent) { |response| done.call(response == "ok") }
    end

    # Shows the configuration *errors* over the window of *parent*, or on
    # their own without one, and yields `true` when the user asks to reload.
    # Returns the dialog and the text buffer that holds the errors.
    def self.config_errors(parent : Widget?, errors : Array(String), &done : Bool ->) : {Void*, Void*}
      dialog = C.adw_alert_dialog_new(DesktopKit.tr("Configuration Errors"),
        DesktopKit.tr("One or more configuration errors were found. Please review the errors below, " \
                      "and either reload your configuration or ignore these errors."))
      C.adw_alert_dialog_add_response(dialog, "ignore", DesktopKit.tr("Ignore"))
      C.adw_alert_dialog_add_response(dialog, "reload", DesktopKit.tr("Reload Configuration"))
      C.adw_alert_dialog_set_response_appearance(dialog, "reload", C::AdwResponseAppearance::Suggested)
      C.adw_alert_dialog_set_default_response(dialog, "ignore")
      C.adw_alert_dialog_set_close_response(dialog, "ignore")
      scrolled, buffer = text_view(errors.join('\n'), 500, 100)
      C.adw_alert_dialog_set_extra_child(dialog, scrolled)
      choose(dialog, parent) { |response| done.call(response == "reload") }
      {dialog, buffer}
    end

    # Asks for a line of text, starting from *text*, and yields the entered
    # text. Yields nothing when the user cancels.
    def self.prompt(parent : Widget, heading : String, body : String?, text : String, confirm : String,
                    cancel : String, &done : String ->) : Nil
      dialog = C.adw_alert_dialog_new(heading, body)
      entry = C.gtk_entry_new
      C.gtk_editable_set_text(entry, text)
      C.gtk_entry_set_activates_default(entry, 1)
      C.adw_alert_dialog_set_extra_child(dialog, entry)
      C.adw_alert_dialog_add_response(dialog, "cancel", cancel)
      C.adw_alert_dialog_add_response(dialog, "ok", confirm)
      C.adw_alert_dialog_set_response_appearance(dialog, "ok", C::AdwResponseAppearance::Suggested)
      C.adw_alert_dialog_set_default_response(dialog, "ok")
      C.adw_alert_dialog_set_close_response(dialog, "cancel")
      C.adw_dialog_set_focus(dialog, entry)
      choose(dialog, parent) do |response|
        done.call(Native.string?(C.gtk_editable_get_text(entry)) || "") if response == "ok"
      end
    end

    # Asks whether to close what *kind* names and yields `true` when the
    # user agrees.
    def self.confirm_close(parent : Widget, kind : Close, &done : Bool ->) : Nil
      confirm(parent, kind.heading, kind.body, kind.verb, DesktopKit.tr("Cancel"), destructive: true, &done)
    end

    # Asks for a new title of what *kind* names, starting from *current*, and
    # yields it, or `nil` for a blank entry. Yields nothing when the user
    # cancels.
    def self.prompt_title(parent : Widget, kind : Action::PromptTitle::Kind, current : String?, &done : String? ->) : Nil
      heading = case kind
                in .surface? then DesktopKit.tr("Change Surface Title")
                in .tab?     then DesktopKit.tr("Change Tab Title")
                in .window?  then DesktopKit.tr("Change Window Title")
                end
      prompt(parent, heading, DesktopKit.tr("Leave blank to restore the default title."), current || "", DesktopKit.tr("OK"),
        DesktopKit.tr("Cancel")) do |text|
        title = text.strip
        done.call(title.empty? ? nil : title)
      end
    end

    # Builds an alert asking *heading* with the responses `"cancel"` and
    # `"ok"`.
    private def self.alert(heading : String, body : String?, confirm : String, cancel : String,
                           destructive : Bool) : Void*
      dialog = C.adw_alert_dialog_new(heading, body)
      C.adw_alert_dialog_add_response(dialog, "cancel", cancel)
      C.adw_alert_dialog_add_response(dialog, "ok", confirm)
      appearance = destructive ? C::AdwResponseAppearance::Destructive : C::AdwResponseAppearance::Suggested
      C.adw_alert_dialog_set_response_appearance(dialog, "ok", appearance)
      C.adw_alert_dialog_set_default_response(dialog, destructive ? "cancel" : "ok")
      C.adw_alert_dialog_set_close_response(dialog, "cancel")
      dialog
    end

    # Builds a read-only, scrolling view of *text* at least *width* by
    # *height* pixels; returns the scrolled window and the text buffer.
    private def self.text_view(text : String, width : Int32, height : Int32) : {Void*, Void*}
      view = C.gtk_text_view_new
      C.gtk_text_view_set_editable(view, 0)
      C.gtk_text_view_set_cursor_visible(view, 0)
      C.gtk_text_view_set_monospace(view, 1)
      C.gtk_text_view_set_wrap_mode(view, C::GtkWrapMode::WordChar)
      C.gtk_text_view_set_top_margin(view, 8)
      C.gtk_text_view_set_bottom_margin(view, 8)
      C.gtk_text_view_set_left_margin(view, 8)
      C.gtk_text_view_set_right_margin(view, 8)
      buffer = C.gtk_text_view_get_buffer(view)
      C.gtk_text_buffer_set_text(buffer, text, text.bytesize)
      scrolled = C.gtk_scrolled_window_new
      C.gtk_scrolled_window_set_min_content_width(scrolled, width)
      C.gtk_scrolled_window_set_min_content_height(scrolled, height)
      C.gtk_scrolled_window_set_child(scrolled, view)
      {scrolled, buffer}
    end

    private def self.choose(dialog : Void*, parent : Widget?, &block : String ->) : Nil
      C.adw_alert_dialog_choose(dialog, parent.try(&.to_unsafe) || Pointer(Void).null, nil, CHOSEN, Handles.retain(block))
    end
  end
end
