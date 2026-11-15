# src/apprt/ui/command_palette.cr
module Apprt
  # Entry of the command palette: a title shown to the user and the action
  # it performs.
  #
  # ```
  # app.commands = Apprt::Command.defaults + [
  #   Apprt::Command.new("Open Settings", MyApp::OpenSettings.new),
  # ]
  # ```
  struct Command
    getter title : String

    getter action : Action

    # Returns the text matched by the search besides the title.
    getter description : String

    def initialize(@title : String, @action : Action, @description : String = "")
    end

    # Returns the commands of the built-in actions that need no input.
    def self.defaults : Array(Command)
      [
        new("New Window", Action::NewWindow.new),
        new("Close All Windows", Action::CloseAllWindows.new),
        new("Reload Configuration", Action::ReloadConfig.new),
        new("Quit", Action::Quit.new),
        new("Close Window", Action::CloseWindow.new),
        new("Toggle Maximize", Action::ToggleMaximize.new),
        new("Toggle Fullscreen", Action::ToggleFullscreen.new),
        new("Toggle Window Decorations", Action::ToggleWindowDecorations.new),
        new("Toggle Background Opacity", Action::ToggleBackgroundOpacity.new),
        new("Reset Window Size", Action::ResetWindowSize.new),
        new("Hide All Windows", Action::ToggleVisibility.new),
        new("GTK Inspector", Action::ShowGtkInspector.new),
        new("Undo Close", Action::Undo.new),
        new("Redo Close", Action::Redo.new),
        new("Change Window Title", Action::PromptTitle.new(:window)),
        new("Tab Overview", Action::ToggleTabOverview.new),
        new("New Tab", Action::NewTab.new),
        new("Previous Tab", Action::GotoTab.new(Action::GotoTab::PREVIOUS)),
        new("Next Tab", Action::GotoTab.new(Action::GotoTab::NEXT)),
        new("Close Tab", Action::CloseTab.new(:this)),
        new("Close Other Tabs", Action::CloseTab.new(:other)),
        new("Close Tabs to the Right", Action::CloseTab.new(:right)),
        new("Move Tab to New Window", Action::MoveTabToNewWindow.new),
        new("Change Tab Title", Action::PromptTitle.new(:tab)),
        new("Copy Title", Action::CopyTitleToClipboard.new),
        new("Toggle Read-Only", Action::ToggleReadOnly.new),
        new("Show On-Screen Keyboard", Action::ShowOnScreenKeyboard.new),
        new("Split Right", Action::NewSplit.new(:right)),
        new("Split Down", Action::NewSplit.new(:down)),
        new("Split Left", Action::NewSplit.new(:left)),
        new("Split Up", Action::NewSplit.new(:up)),
        new("Focus Previous Split", Action::GotoSplit.new(:previous)),
        new("Focus Next Split", Action::GotoSplit.new(:next)),
        new("Equalize Splits", Action::EqualizeSplits.new),
        new("Toggle Split Zoom", Action::ToggleSplitZoom.new),
        new("Close Split", Action::CloseSurface.new),
        new("Change Title", Action::PromptTitle.new(:surface)),
      ]
    end

    # Whether every word of *query* appears in the title or the
    # description, ignoring case.
    def matches?(query : String) : Bool
      text = "#{@title} #{@description}".downcase
      query.downcase.split.all? { |word| text.includes?(word) }
    end
  end

  # :nodoc:
  # The command palette of one window, after Ghostty's
  # src/apprt/gtk/class/command_palette.zig: an `AdwDialog` with a search
  # entry over a list of the application's commands. Typing filters the
  # rows, Up and Down move the selection, Enter or a click performs the
  # selected command on the window after the dialog closes.
  class CommandPalette
    private KEY_UP   = 0xff52_u32
    private KEY_DOWN = 0xff54_u32

    getter dialog : Widget

    @rows = [] of Void*
    @closed = false

    def initialize(@window : Window, @app : App, @commands : Array(Command), bindings : Array(Binding))
      @dialog = Widget.new(C.adw_dialog_new)
      C.adw_dialog_set_title(@dialog, "Command Palette")
      C.adw_dialog_set_content_width(@dialog, 480)

      @entry = Widget.new(C.gtk_search_entry_new)
      @list = Widget.new(C.gtk_list_box_new)
      C.gtk_list_box_set_selection_mode(@list, C::GtkSelectionMode::Browse)
      C.gtk_list_box_set_activate_on_single_click(@list, 1)
      @list.add_css_class("boxed-list")

      labels = {} of String => String
      bindings.each { |binding| labels[binding.action.detailed_name] ||= binding.label unless binding.global? }
      @commands.each { |command| append(command, labels[command.action.detailed_name]?) }

      scrolled = C.gtk_scrolled_window_new
      C.gtk_scrolled_window_set_policy(scrolled, C::GtkPolicyType::Never, C::GtkPolicyType::Automatic)
      C.gtk_scrolled_window_set_propagate_natural_height(scrolled, 1)
      C.gtk_scrolled_window_set_max_content_height(scrolled, 400)
      C.gtk_scrolled_window_set_child(scrolled, @list)

      box = Widget.new(C.gtk_box_new(C::GtkOrientation::Vertical, 12))
      margins(box, 12)
      C.gtk_box_append(box, @entry)
      C.gtk_box_append(box, scrolled)
      C.adw_dialog_set_child(@dialog, box)
      C.adw_dialog_set_focus(@dialog, @entry)

      connect_signals
      filter
    end

    def present : Nil
      C.adw_dialog_present(@dialog, @window.widget)
    end

    def close : Nil
      C.adw_dialog_force_close(@dialog) unless @closed
    end

    def closed? : Bool
      @closed
    end

    # Returns the commands of the rows shown, in order.
    def shown : Array(Command)
      @commands.select(&.matches?(query))
    end

    # Returns the command of the selected row.
    def selected : Command?
      row = C.gtk_list_box_get_selected_row(@list)
      @commands[C.gtk_list_box_row_get_index(row)] unless row.null?
    end

    def query : String
      String.new(C.gtk_editable_get_text(@entry))
    end

    # Moves the selection *step* shown rows on, stopping at either end.
    def move(step : Int32) : Nil
      visible = @rows.select { |row| C.gtk_widget_get_visible(row) != 0 }
      return if visible.empty?
      current = visible.index(C.gtk_list_box_get_selected_row(@list)) || (step > 0 ? -1 : visible.size)
      C.gtk_list_box_select_row(@list, visible[(current + step).clamp(0, visible.size - 1)])
    end

    # Closes the dialog and performs the selected command.
    def activate : Nil
      run(selected)
    end

    private def append(command : Command, shortcut : String?) : Nil
      box = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 12))
      margins(box, 8)
      title = Widget.new(C.gtk_label_new(command.title))
      C.gtk_label_set_xalign(title, 0)
      title.hexpand = true
      C.gtk_box_append(box, title)
      if shortcut
        label = Widget.new(C.gtk_label_new(shortcut))
        label.add_css_class("dim-label")
        C.gtk_box_append(box, label)
      end
      row = C.gtk_list_box_row_new
      C.gtk_list_box_row_set_child(row, box)
      C.gtk_list_box_append(@list, row)
      @rows << row
    end

    private def connect_signals : Nil
      Signals.connect(@entry, "search-changed", -> { filter })
      Signals.connect(@entry, "activate", -> { activate })
      Signals.connect(@entry, "stop-search", -> { close })
      Signals.connect(@list, "row-activated", ->(row : Void*) { run(@commands[C.gtk_list_box_row_get_index(row)]) })
      Signals.connect(@dialog, "closed", -> { @closed = true; nil })
      keys = C.gtk_event_controller_key_new
      Signals.connect(keys, "key-pressed", ->(keyval : UInt32, _keycode : UInt32, _state : UInt32) : Bool {
        case keyval
        when KEY_UP   then move(-1)
        when KEY_DOWN then move(1)
        else               return false
        end
        true
      })
      @entry.add_controller(keys)
    end

    # Shows the rows matching the query and selects the first of them.
    private def filter : Nil
      text = query
      first = nil
      @rows.each_with_index do |row, index|
        visible = @commands[index].matches?(text)
        C.gtk_widget_set_visible(row, visible ? 1 : 0)
        first ||= row if visible
      end
      C.gtk_list_box_select_row(@list, first || Pointer(Void).null)
    end

    private def run(command : Command?) : Nil
      close
      return unless command
      Log.warn { "command #{command.title}: action #{command.action.detailed_name} not handled" } unless @app.perform_in(@window, command.action)
    end

    private def margins(widget : Widget, margin : Int32) : Nil
      C.gtk_widget_set_margin_start(widget, margin)
      C.gtk_widget_set_margin_end(widget, margin)
      C.gtk_widget_set_margin_top(widget, margin)
      C.gtk_widget_set_margin_bottom(widget, margin)
    end
  end

  abstract class App
    @commands : Array(Command) = Command.defaults

    # Returns the commands of the command palette; `Command.defaults` until
    # replaced.
    def commands : Array(Command)
      @commands.dup
    end

    # Replaces the commands of the command palette. Windows read them each
    # time the palette opens.
    def commands=(commands : Enumerable(Command)) : Enumerable(Command)
      @commands = commands.to_a
      commands
    end

    protected def perform(target : Window, action : Action::ToggleCommandPalette) : Bool
      target.toggle_command_palette(@commands, @bindings)
      true
    end
  end
end
