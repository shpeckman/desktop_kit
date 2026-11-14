# src/apprt/dialogs.cr
module Apprt
  # :nodoc:
  # Libadwaita alert dialogs, after Ghostty's close_confirmation_dialog.zig
  # and title_dialog.zig. A dialog answers once through
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
        in .app?     then "Quit?"
        in .windows? then "Close All Windows?"
        in .window?  then "Close Window?"
        in .tab?     then "Close Tab?"
        in .split?   then "Close Split?"
        end
      end

      def body : String
        case self
        in .app?, .windows? then "Unsaved work will be lost."
        in .window?         then "Unsaved work in this window will be lost."
        in .tab?            then "Unsaved work in this tab will be lost."
        in .split?          then "Unsaved work in this split will be lost."
        end
      end

      def verb : String
        app? ? "Quit" : "Close"
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

    # Asks whether to close what *kind* names, over the window of *parent*,
    # and yields `true` when the user agrees.
    def self.confirm_close(parent : Widget, kind : Close, &done : Bool ->) : Nil
      dialog = C.adw_alert_dialog_new(kind.heading, kind.body)
      C.adw_alert_dialog_add_response(dialog, "cancel", "Cancel")
      C.adw_alert_dialog_add_response(dialog, "close", kind.verb)
      C.adw_alert_dialog_set_response_appearance(dialog, "close", C::AdwResponseAppearance::Destructive)
      C.adw_alert_dialog_set_default_response(dialog, "cancel")
      C.adw_alert_dialog_set_close_response(dialog, "cancel")
      choose(dialog, parent) { |response| done.call(response == "close") }
    end

    # Asks for a new title of what *kind* names, starting from *current*, and
    # yields it, or `nil` for a blank entry. Yields nothing when the user
    # cancels.
    def self.prompt_title(parent : Widget, kind : Action::PromptTitle::Kind, current : String?, &done : String? ->) : Nil
      dialog = C.adw_alert_dialog_new("Change #{kind} Title", "Leave blank to restore the default title.")
      entry = C.gtk_entry_new
      C.gtk_editable_set_text(entry, current || "")
      C.gtk_entry_set_activates_default(entry, 1)
      C.adw_alert_dialog_set_extra_child(dialog, entry)
      C.adw_alert_dialog_add_response(dialog, "cancel", "Cancel")
      C.adw_alert_dialog_add_response(dialog, "ok", "OK")
      C.adw_alert_dialog_set_response_appearance(dialog, "ok", C::AdwResponseAppearance::Suggested)
      C.adw_alert_dialog_set_default_response(dialog, "ok")
      C.adw_alert_dialog_set_close_response(dialog, "cancel")
      C.adw_dialog_set_focus(dialog, entry)
      choose(dialog, parent) do |response|
        next unless response == "ok"
        title = (Native.string?(C.gtk_editable_get_text(entry)) || "").strip
        done.call(title.empty? ? nil : title)
      end
    end

    private def self.choose(dialog : Void*, parent : Widget, &block : String ->) : Nil
      C.adw_alert_dialog_choose(dialog, parent, nil, CHOSEN, Handles.retain(block))
    end
  end
end
