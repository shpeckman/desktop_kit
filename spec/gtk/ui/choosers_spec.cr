# spec/gtk/ui/choosers_spec.cr
require "../harness"

lib ChoosersSpecLib
  fun gtk_window_get_toplevels : Void*
  fun g_list_model_get_n_items(list : Void*) : UInt32
  fun g_list_model_get_item(list : Void*, position : UInt32) : Void*
  fun g_type_name_from_instance(instance : Void*) : UInt8*
  fun g_object_unref(object : Void*)
  fun adw_about_dialog_get_application_name(dialog : Void*) : UInt8*
  fun adw_about_dialog_get_version(dialog : Void*) : UInt8*
  fun adw_about_dialog_get_license_type(dialog : Void*) : Int32
end

# Returns the GType names of the toplevel windows.
private def toplevels : Array(String)
  list = ChoosersSpecLib.gtk_window_get_toplevels
  Array.new(ChoosersSpecLib.g_list_model_get_n_items(list).to_i32) do |index|
    item = ChoosersSpecLib.g_list_model_get_item(list, index.to_u32)
    String.new(ChoosersSpecLib.g_type_name_from_instance(item)).tap { ChoosersSpecLib.g_object_unref(item) }
  end
end

# Answers dialogs of *type* with Cancel, as the user dismissing them.
# Waits first: GTK 4.18 crashes when a file chooser goes while its recent
# files query runs (the query's callback touches the freed
# `GtkFileSystemModel`).
private def dismiss(type : String) : Nil
  # The private bus has no portal, so GTK falls back to
  # `GtkFileChooserDialog` and friends. Cancel via `response`:
  # `gtk_window_close` on the color/font dialogs gave `gtk_window_destroy`
  # criticals.
  settle
  list = ChoosersSpecLib.gtk_window_get_toplevels
  windows = Array.new(ChoosersSpecLib.g_list_model_get_n_items(list).to_i32) do |index|
    ChoosersSpecLib.g_list_model_get_item(list, index.to_u32)
  end
  windows.each do |window|
    Apprt::C.g_signal_emit_by_name(window, "response", -6) if String.new(ChoosersSpecLib.g_type_name_from_instance(window)) == type
    ChoosersSpecLib.g_object_unref(window)
  end
end

describe "Window choosers" do
  before_all { GtkHarness.start }

  it "shows the file chooser and yields nil when dismissed" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      settle
      results = [] of Path?
      window.open_file(folder: Path["/tmp"], filters: [Apprt::FileFilter.new("Text", ["*.txt"], ["text/plain"])]) { |path| results << path }
      eventually { toplevels.includes?("GtkFileChooserDialog") }.should be_true
      dismiss("GtkFileChooserDialog")
      eventually { results.size == 1 }.should be_true
      results.should eq [nil]

      paths = [] of Array(Path)
      window.open_files { |files| paths << files }
      eventually { toplevels.includes?("GtkFileChooserDialog") }.should be_true
      dismiss("GtkFileChooserDialog")
      eventually { paths.size == 1 }.should be_true
      paths.should eq [[] of Path]
    end
  end

  it "shows the color and font choosers" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      settle
      colors = [] of Apprt::Color?
      window.choose_color(color: Apprt::Color.new(1.0, 0.0, 0.0)) { |color| colors << color }
      eventually { toplevels.includes?("GtkColorChooserDialog") }.should be_true
      dismiss("GtkColorChooserDialog")
      eventually { colors.size == 1 }.should be_true
      colors.should eq [nil]

      fonts = [] of String?
      window.choose_font(font: "Monospace 12") { |font| fonts << font }
      eventually { toplevels.includes?("GtkFontChooserDialog") }.should be_true
      dismiss("GtkFontChooserDialog")
      eventually { fonts.size == 1 }.should be_true
      fonts.should eq [nil]
    end
  end

  it "shows the about dialog" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      settle
      window.show_about(Apprt::About.new("Editor", version: "1.2", developers: ["Ann <ann@example.org>"], license: :mit))
      settle
      dialog = Apprt::C.adw_application_window_get_visible_dialog(window.widget)
      dialog.null?.should be_false
      String.new(ChoosersSpecLib.adw_about_dialog_get_application_name(dialog)).should eq "Editor"
      String.new(ChoosersSpecLib.adw_about_dialog_get_version(dialog)).should eq "1.2"
      ChoosersSpecLib.adw_about_dialog_get_license_type(dialog).should eq Apprt::C::GtkLicense::MitX11.value
      Apprt::C.adw_dialog_force_close(dialog)
    end
  end

  it "skips dialogs of a closed window" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      window.close
      eventually { window.closed? }.should be_true
      called = false
      window.open_file { called = true }
      window.choose_font { called = true }
      settle
      called.should be_false
      toplevels.includes?("GtkFileChooserDialog").should be_false
    end
  end
end
