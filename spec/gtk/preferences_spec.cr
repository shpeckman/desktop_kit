# spec/gtk/preferences_spec.cr
require "./harness"

lib PreferencesSpecLib
  fun gtk_widget_get_first_child(widget : Void*) : Void*
  fun gtk_widget_get_next_sibling(widget : Void*) : Void*
  fun g_type_name_from_instance(instance : Void*) : UInt8*
  fun adw_switch_row_get_active(row : Void*) : Int32
  fun adw_switch_row_set_active(row : Void*, active : Int32)
  fun gtk_editable_get_text(editable : Void*) : UInt8*
  fun gtk_editable_set_text(editable : Void*, text : UInt8*)
  fun adw_spin_row_get_value(row : Void*) : Float64
  fun adw_spin_row_set_value(row : Void*, value : Float64)
  fun adw_combo_row_get_selected(row : Void*) : UInt32
  fun adw_combo_row_set_selected(row : Void*, position : UInt32)
  fun adw_preferences_row_get_title(row : Void*) : UInt8*
end

# Returns the widgets below *widget* whose type is named *type*, depth first.
private def widgets(widget : Void*, type : String, found = [] of Void*) : Array(Void*)
  child = PreferencesSpecLib.gtk_widget_get_first_child(widget)
  until child.null?
    found << child if String.new(PreferencesSpecLib.g_type_name_from_instance(child)) == type
    widgets(child, type, found)
    child = PreferencesSpecLib.gtk_widget_get_next_sibling(child)
  end
  found
end

private def row(prefs : Apprt::Preferences, type : String) : Void*
  rows = widgets(prefs.@dialog, type)
  rows.size.should eq 1
  rows.first
end

private def title(row : Void*) : String
  String.new(PreferencesSpecLib.adw_preferences_row_get_title(row))
end

private def preferences(changes : Array(String)) : Apprt::Preferences
  Apprt::Preferences.new("Settings").tap do |prefs|
    prefs.page("General", icon: "preferences-system-symbolic") do |page|
      page.group("Look", description: "How it looks") do |group|
        group.switch("Dark", subtitle: "Use dark colours", value: true) { |dark| changes << "dark #{dark}" }
        group.choice("Theme", ["Light", "Dark", "Auto"], selected: 2) { |index| changes << "theme #{index}" }
      end
    end
    prefs.page("Text") do |page|
      page.group do |group|
        group.entry("Name", value: "apprt") { |text| changes << "name #{text}" }
        group.spin("Size", value: 12.0, range: 6.0..72.0, step: 0.5, digits: 1) { |size| changes << "size #{size}" }
      end
    end
  end
end

describe Apprt::Preferences do
  before_all { GtkHarness.start }

  it "shows its rows with their values and reports changes" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      changes = [] of String
      prefs = preferences(changes)
      prefs.open?.should be_false
      prefs.present(window)
      prefs.open?.should be_true
      dark = row(prefs, "AdwSwitchRow")
      theme = row(prefs, "AdwComboRow")
      name = row(prefs, "AdwEntryRow")
      size = row(prefs, "AdwSpinRow")
      {dark, theme, name, size}.map { |widget| title(widget) }.should eq({"Dark", "Theme", "Name", "Size"})
      PreferencesSpecLib.adw_switch_row_get_active(dark).should eq 1
      PreferencesSpecLib.adw_combo_row_get_selected(theme).should eq 2
      String.new(PreferencesSpecLib.gtk_editable_get_text(name)).should eq "apprt"
      PreferencesSpecLib.adw_spin_row_get_value(size).should eq 12.0
      changes.should be_empty

      PreferencesSpecLib.adw_switch_row_set_active(dark, 0)
      PreferencesSpecLib.adw_combo_row_set_selected(theme, 0)
      PreferencesSpecLib.gtk_editable_set_text(name, "other")
      PreferencesSpecLib.adw_spin_row_set_value(size, 14.5)
      changes.should eq ["dark false", "theme 0", "name other", "size 14.5"]
      prefs.close
      prefs.open?.should be_false
    end
  end

  it "shows the values chosen before when presented again" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      changes = [] of String
      prefs = preferences(changes)
      prefs.present(window)
      PreferencesSpecLib.adw_switch_row_set_active(row(prefs, "AdwSwitchRow"), 0)
      PreferencesSpecLib.gtk_editable_set_text(row(prefs, "AdwEntryRow"), "kept")
      prefs.close
      settle
      prefs.present(window)
      PreferencesSpecLib.adw_switch_row_get_active(row(prefs, "AdwSwitchRow")).should eq 0
      String.new(PreferencesSpecLib.gtk_editable_get_text(row(prefs, "AdwEntryRow"))).should eq "kept"
      prefs.present(window)
      prefs.open?.should be_true
      changes.should eq ["dark false", "name kept"]
      prefs.close
    end
  end

  it "rejects a choice without options or outside them" do
    prefs = Apprt::Preferences.new
    prefs.page("Page") do |page|
      page.group do |group|
        expect_raises(ArgumentError) { group.choice("Empty", [] of String) { } }
        expect_raises(IndexError) { group.choice("Out", ["a"], selected: 1) { } }
      end
    end
  end
end
