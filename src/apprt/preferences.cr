# src/apprt/preferences.cr
module Apprt
  # A preferences dialog: pages of titled groups of rows, each row editing
  # one value and reporting changes to its block.
  #
  # ```
  # prefs = Apprt::Preferences.new("Preferences")
  # prefs.page("General", icon: "preferences-system-symbolic") do |page|
  #   page.group("Appearance") do |group|
  #     group.switch("Dark mode", value: true) { |dark| app.appearance = ... }
  #     group.spin("Font size", value: 12.0, range: 6.0..72.0) { |size| ... }
  #     group.choice("Theme", ["Light", "Dark"]) { |index| ... }
  #   end
  # end
  # prefs.present(window)
  # ```
  #
  # Each row keeps its current value, so presenting the dialog again shows
  # the values chosen before.
  class Preferences
    # A page of the dialog, listed in its sidebar or view switcher.
    class Page
      getter title : String
      getter icon : String?

      @groups = [] of Group

      protected def initialize(@title : String, @icon : String?)
      end

      # Adds a group of rows titled *title* (empty for none) with an optional
      # *description* below it, and yields it.
      def group(title : String = "", description : String? = nil, & : Group ->) : Group
        group = Group.new(title, description)
        @groups << group
        yield group
        group
      end

      protected def build : Void*
        page = C.adw_preferences_page_new
        C.adw_preferences_page_set_title(page, @title)
        C.adw_preferences_page_set_icon_name(page, Native.string(@icon))
        @groups.each { |group| C.adw_preferences_page_add(page, group.build) }
        page
      end
    end

    # A titled list of rows.
    class Group
      getter title : String
      getter description : String?

      @rows = [] of Row

      protected def initialize(@title : String, @description : String?)
      end

      # Adds a row with a switch showing *value*; the block receives each new
      # state.
      def switch(title : String, *, subtitle : String? = nil, value : Bool = false, &on_change : Bool ->) : Nil
        @rows << SwitchRow.new(title, subtitle, value, on_change)
      end

      # Adds a row with a text entry holding *value*; the block receives the
      # text after each edit.
      def entry(title : String, *, value : String = "", &on_change : String ->) : Nil
        @rows << EntryRow.new(title, nil, value, on_change)
      end

      # Adds a row with a spin button showing *value* within *range*, moving
      # by *step* and showing *digits* decimals; the block receives each new
      # value.
      def spin(title : String, *, subtitle : String? = nil, value : Float64, range : Range(Float64, Float64),
               step : Float64 = 1.0, digits : Int32 = 0, &on_change : Float64 ->) : Nil
        @rows << SpinRow.new(title, subtitle, value, range, step, digits, on_change)
      end

      # Adds a row choosing one of *options*, with the option at *selected*
      # chosen; the block receives the index of each new choice.
      def choice(title : String, options : Array(String), *, subtitle : String? = nil, selected : Int32 = 0,
                 &on_change : Int32 ->) : Nil
        raise ArgumentError.new("no options for #{title}") if options.empty?
        raise IndexError.new("selected #{selected} outside #{options.size} options") unless 0 <= selected < options.size
        @rows << ChoiceRow.new(title, subtitle, selected, options, on_change)
      end

      protected def build : Void*
        group = C.adw_preferences_group_new
        C.adw_preferences_group_set_title(group, @title)
        C.adw_preferences_group_set_description(group, Native.string(@description))
        @rows.each { |row| C.adw_preferences_group_add(group, row.build) }
        group
      end
    end

    # A row: its title, the value it holds and the change callback.
    private abstract class Row
      def initialize(@title : String, @subtitle : String?)
      end

      # Builds the row widget showing the current value and connects its
      # change signal.
      def build : Void*
        row = widget
        C.adw_preferences_row_set_title(row, @title)
        @subtitle.try { |subtitle| C.adw_action_row_set_subtitle(row, subtitle) }
        connect(row)
        row
      end

      private abstract def widget : Void*
      private abstract def connect(row : Void*) : Nil
    end

    private class SwitchRow < Row
      def initialize(title, subtitle, @value : Bool, @on_change : Bool ->)
        super(title, subtitle)
      end

      private def widget : Void*
        C.adw_switch_row_new.tap { |row| C.adw_switch_row_set_active(row, @value ? 1 : 0) }
      end

      private def connect(row : Void*) : Nil
        Signals.notify(row, "active", -> {
          @value = C.adw_switch_row_get_active(row) != 0
          @on_change.call(@value)
        })
      end
    end

    private class EntryRow < Row
      def initialize(title, subtitle, @value : String, @on_change : String ->)
        super(title, subtitle)
      end

      private def widget : Void*
        C.adw_entry_row_new.tap { |row| C.gtk_editable_set_text(row, @value) }
      end

      private def connect(row : Void*) : Nil
        Signals.notify(row, "text", -> {
          @value = Native.string?(C.gtk_editable_get_text(row)) || ""
          @on_change.call(@value)
        })
      end
    end

    private class SpinRow < Row
      def initialize(title, subtitle, @value : Float64, @range : Range(Float64, Float64), @step : Float64,
                     @digits : Int32, @on_change : Float64 ->)
        super(title, subtitle)
      end

      private def widget : Void*
        row = C.adw_spin_row_new_with_range(@range.begin, @range.end, @step)
        C.adw_spin_row_set_digits(row, @digits.to_u32)
        C.adw_spin_row_set_value(row, @value)
        row
      end

      private def connect(row : Void*) : Nil
        Signals.notify(row, "value", -> {
          @value = C.adw_spin_row_get_value(row)
          @on_change.call(@value)
        })
      end
    end

    private class ChoiceRow < Row
      def initialize(title, subtitle, @value : Int32, @options : Array(String), @on_change : Int32 ->)
        super(title, subtitle)
      end

      private def widget : Void*
        row = C.adw_combo_row_new
        strings = Native.strv(@options)
        model = C.gtk_string_list_new(strings.to_unsafe)
        C.adw_combo_row_set_model(row, model)
        C.g_object_unref(model)
        C.adw_combo_row_set_selected(row, @value.to_u32)
        row
      end

      private def connect(row : Void*) : Nil
        Signals.notify(row, "selected", -> {
          @value = C.adw_combo_row_get_selected(row).to_i32
          @on_change.call(@value)
        })
      end
    end

    getter title : String
    @pages = [] of Page

    @dialog : Void* = Pointer(Void).null

    # Creates an empty dialog titled *title*.
    def initialize(@title : String = "Preferences")
    end

    # Adds a page titled *title* with the themed icon *icon* and yields it.
    def page(title : String, *, icon : String? = nil, & : Page ->) : Page
      page = Page.new(title, icon)
      @pages << page
      yield page
      page
    end

    # Returns whether the dialog is shown.
    def open? : Bool
      !@dialog.null?
    end

    # Shows the dialog over *window*, closing an earlier one first. Call it on
    # the GTK thread.
    def present(window : Window) : Nil
      UIThread.assert!
      close
      dialog = C.adw_preferences_dialog_new
      C.adw_dialog_set_title(dialog, @title)
      @pages.each { |page| C.adw_preferences_dialog_add(dialog, page.build) }
      Signals.connect(dialog, "closed", -> { @dialog = Pointer(Void).null if @dialog == dialog; nil })
      @dialog = dialog
      C.adw_dialog_present(dialog, window.widget)
    end

    # Closes the dialog if it is shown.
    def close : Nil
      C.adw_dialog_force_close(@dialog) unless @dialog.null?
      @dialog = Pointer(Void).null
    end
  end
end
