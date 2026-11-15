# spec/gtk/ui/banner_spec.cr
require "../harness"

private def banner_bar(surface : Apprt::Surface) : Void*
  surface.@banner_bar.to_unsafe
end

private def revealed?(surface : Apprt::Surface) : Bool
  Apprt::C.adw_banner_get_revealed(banner_bar(surface)) != 0
end

describe "Surface#show_banner" do
  before_all { GtkHarness.start }

  it "shows a message with a button until hidden" do
    run_steps(TestApp.new) do |app|
      surface = app.new_window.active_surface.not_nil!
      surface.banner.should be_nil
      revealed?(surface).should be_false

      clicks = 0
      surface.show_banner("Connection lost", "Reconnect") { clicks += 1 }
      surface.banner.should eq "Connection lost"
      revealed?(surface).should be_true
      Apprt::Native.string?(Apprt::C.adw_banner_get_title(banner_bar(surface))).should eq "Connection lost"
      Apprt::Native.string?(Apprt::C.adw_banner_get_button_label(banner_bar(surface))).should eq "Reconnect"

      Apprt::C.g_signal_emit_by_name(banner_bar(surface), "button-clicked")
      clicks.should eq 1
      surface.banner.should eq "Connection lost"

      surface.hide_banner
      surface.banner.should be_nil
      revealed?(surface).should be_false
    end
  end

  it "shows a message without a button" do
    run_steps(TestApp.new) do |app|
      surface = app.new_window.active_surface.not_nil!
      surface.show_banner("Read-only file system")
      revealed?(surface).should be_true
      Apprt::Native.string?(Apprt::C.adw_banner_get_button_label(banner_bar(surface))).should be_nil
    end
  end

  it "replaces the button action" do
    run_steps(TestApp.new) do |app|
      surface = app.new_window.active_surface.not_nil!
      clicks = [] of String
      surface.show_banner("First", "Retry") { clicks << "first" }
      surface.show_banner("Second", "Retry") { clicks << "second" }
      Apprt::C.g_signal_emit_by_name(banner_bar(surface), "button-clicked")
      clicks.should eq ["second"]
      surface.banner.should eq "Second"
    end
  end
end
