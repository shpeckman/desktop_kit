# spec/gtk/ui/progress_spec.cr
require "../harness"

lib ProgressSpecLib
  fun gtk_progress_bar_get_fraction(pbar : Void*) : Float64
  fun adw_tab_page_get_loading(page : Void*) : Int32
  fun adw_tab_view_get_selected_page(view : Void*) : Void*
  fun gtk_widget_has_css_class(widget : Void*, name : UInt8*) : Int32
end

# Updates sent to the launcher entry, as {app uri, progress, visible}.
private UPDATES = [] of {String, Float64, Bool}

private UPDATE = ->(connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, signal : UInt8*, parameters : Void*, data : Void*) do
  uri, properties = Apprt::Variant.from_raw(parameters).get(Tuple(String, Hash(String, Apprt::Variant)))
  UPDATES << {uri, properties["progress"].get(Float64), properties["progress-visible"].get(Bool)}
  nil
end

private def loading?(window : Apprt::Window) : Bool
  ProgressSpecLib.adw_tab_page_get_loading(ProgressSpecLib.adw_tab_view_get_selected_page(window.@tab_view)) != 0
end

describe Apprt::Progress do
  before_all { GtkHarness.start }

  it "clamps the value and reports indeterminate progress" do
    Apprt::Progress.new(1.5).value.should eq 1.0
    Apprt::Progress.new(-1.0).value.should eq 0.0
    Apprt::Progress.new.indeterminate?.should be_true
    Apprt::Progress.new(0.5, :error).state.error?.should be_true
  end

  it "shows progress on the surface, the tab and the launcher entry" do
    app = TestApp.new
    UPDATES.clear
    run_steps(app) do
      connection = Apprt::C.g_application_get_dbus_connection(app)
      Apprt::C.g_dbus_connection_signal_subscribe(connection, nil, "com.canonical.Unity.LauncherEntry", "Update",
        nil, nil, Apprt::C::GDBusSignalFlags::None, UPDATE, nil, nil)
      window = app.new_window
      settle
      first = window.active_tab.not_nil!.surfaces.first
      second = first.split(:right)
      settle
      bar = first.@progress_bar
      bar.visible?.should be_false
      loading?(window).should be_false

      first.progress = Apprt::Progress.new(0.4)
      second.progress = Apprt::Progress.new(0.8, :paused)
      settle
      bar.visible?.should be_true
      ProgressSpecLib.gtk_progress_bar_get_fraction(bar).should eq 0.4
      ProgressSpecLib.gtk_widget_has_css_class(second.@progress_bar, "paused").should eq 1
      loading?(window).should be_true
      eventually { UPDATES.last?.try { |update| (update[1] - 0.6).abs < 1e-9 } || false }
      UPDATES.last.should eq({"application://#{app.id}.desktop", UPDATES.last[1], true})

      first.progress = Apprt::Progress.new
      settle
      eventually { UPDATES.last?.try { |update| (update[1] - 0.4).abs < 1e-9 } || false }

      first.progress = nil
      second.progress = nil
      settle
      bar.visible?.should be_false
      loading?(window).should be_false
      eventually { UPDATES.last? == {"application://#{app.id}.desktop", 0.0, false} }
    end
  end
end
