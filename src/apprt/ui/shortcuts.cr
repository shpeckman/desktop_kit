# src/apprt/ui/shortcuts.cr
module Apprt
  # :nodoc:
  # The keyboard shortcuts dialog of one window: an `AdwPreferencesDialog`
  # with search, a group per action scope listing the bindings, then a
  # group per key table. A row's title is the title of the command with the
  # same action, else the action name in words; the trigger labels sit at
  # its end.
  class ShortcutsDialog
    # Why not native: libadwaita 1.7 has no `AdwShortcutsDialog`,
    # `GtkShortcutsWindow` is deprecated. Preferences dialog gives search.

    # Title and row of one listed binding.
    record Entry, title : String, shortcut : String, global : Bool

    getter dialog : Widget

    @closed = false

    def initialize(@window : Window, commands : Array(Command), bindings : Array(Binding),
                   key_tables : Hash(String, Array(Binding)))
      titles = {} of String => String
      commands.each { |command| titles[command.action.detailed_name] ||= command.title }

      @groups = [] of {String, String?, Array(Entry)}
      Action::Scope.each do |scope|
        entries = bindings.select { |binding| binding.action.scope == scope }.map { |binding| entry(binding, titles) }
        @groups << {scope_title(scope), nil, entries} unless entries.empty?
      end
      key_tables.keys.sort!.each do |name|
        entries = key_tables[name].map { |binding| entry(binding, titles) }
        @groups << {name, Apprt.tr("Key table"), entries} unless entries.empty?
      end

      @dialog = Widget.new(C.adw_preferences_dialog_new)
      C.adw_dialog_set_title(@dialog, Apprt.tr("Keyboard Shortcuts"))
      C.adw_preferences_dialog_set_search_enabled(@dialog, 1)
      C.adw_preferences_dialog_add(@dialog, build_page)
      Signals.connect(@dialog, "closed", -> { @closed = true; nil })
    end

    # Returns the group titles with their entries, in the order shown.
    def groups : Array({String, Array(Entry)})
      @groups.map { |title, _, entries| {title, entries} }
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

    private def entry(binding : Binding, titles : Hash(String, String)) : Entry
      action = binding.action
      Entry.new(titles[action.detailed_name]? || action_title(action), binding.label, binding.global?)
    end

    # Returns the action name in words with its payload, such as
    # `"New split (right)"`.
    private def action_title(action : Action) : String
      words = action.name.tr("-", " ").capitalize
      payload = action.to_variant || return words
      "#{words} (#{payload.to_s.lchop('(').rchop(')').delete('\'')})"
    end

    private def scope_title(scope : Action::Scope) : String
      case scope
      in .app?    then Apprt.tr("Application")
      in .window? then Apprt.tr("Window")
      in .tab?    then Apprt.tr("Tab")
      in .split?  then Apprt.tr("Split")
      end
    end

    private def build_page : Void*
      page = C.adw_preferences_page_new
      @groups.each do |title, description, entries|
        group = C.adw_preferences_group_new
        C.adw_preferences_group_set_title(group, title)
        description.try { |text| C.adw_preferences_group_set_description(group, text) }
        entries.each { |entry| C.adw_preferences_group_add(group, row(entry)) }
        C.adw_preferences_page_add(page, group)
      end
      page
    end

    private def row(entry : Entry) : Void*
      row = C.adw_action_row_new
      C.adw_preferences_row_set_use_markup(row, 0)
      C.adw_preferences_row_set_title(row, entry.title)
      C.adw_action_row_set_subtitle(row, Apprt.tr("Global shortcut")) if entry.global
      label = Widget.new(C.gtk_label_new(entry.shortcut))
      label.add_css_class("dim-label")
      C.adw_action_row_add_suffix(row, label)
      row
    end
  end

  class Window
    @shortcuts_dialog : ShortcutsDialog?

    # Shows a keyboard shortcuts dialog listing *bindings* and *key_tables*,
    # titled from *commands*, replacing an open one.
    protected def show_shortcuts(commands : Array(Command), bindings : Array(Binding),
                                 key_tables : Hash(String, Array(Binding))) : Nil
      @shortcuts_dialog.try(&.close)
      dialog = ShortcutsDialog.new(self, commands, bindings, key_tables)
      dialog.present
      @shortcuts_dialog = dialog
    end

    # Returns the open keyboard shortcuts dialog.
    protected def shortcuts_dialog : ShortcutsDialog?
      @shortcuts_dialog.try { |dialog| dialog unless dialog.closed? }
    end
  end

  abstract class App
    protected def perform(target : Window, action : Action::ShowShortcuts) : Bool
      target.show_shortcuts(@commands, @bindings, @key_tables)
      true
    end
  end
end
