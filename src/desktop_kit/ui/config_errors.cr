# src/desktop_kit/ui/config_errors.cr
module DesktopKit
  abstract class App
    # The configuration errors the application shows the user.
    getter config_errors : Array(String) = [] of String

    @config_errors_dialog = Pointer(Void).null
    @config_errors_buffer = Pointer(Void).null

    # Shows *errors* in a dialog that offers to reload the configuration
    # (`#reload`) or to ignore them; an empty list closes the dialog.
    #
    # Set it after each load of the configuration, such as in `#on_reload`.
    # Errors set before `#run` show once the application is active.
    def config_errors=(errors : Array(String)) : Array(String)
      @config_errors = errors.dup
      UIThread.dispatch { sync_config_errors } if running?
      errors
    end

    # Opens, updates or closes the dialog to match `#config_errors`.
    private def sync_config_errors : Nil
      return unless @ready
      if @config_errors_dialog.null?
        show_config_errors unless @config_errors.empty?
      elsif @config_errors.empty?
        dialog = @config_errors_dialog
        forget_config_errors_dialog
        C.adw_dialog_close(dialog)
      else
        text = @config_errors.join('\n')
        C.gtk_text_buffer_set_text(@config_errors_buffer, text, text.bytesize)
      end
    end

    private def show_config_errors : Nil
      shown = Pointer(Void).null
      shown, @config_errors_buffer = Dialogs.config_errors(active_window.try(&.widget), @config_errors) do |reload|
        forget_config_errors_dialog if @config_errors_dialog == shown
        reload_now if reload && running?
      end
      @config_errors_dialog = shown
    end

    private def forget_config_errors_dialog : Nil
      @config_errors_dialog = Pointer(Void).null
      @config_errors_buffer = Pointer(Void).null
    end
  end
end
