# spec/gtk/bell_spec.cr
require "./harness"

private def border_shown?(surface : Apprt::Surface) : Bool
  Apprt::C.gtk_revealer_get_reveal_child(surface.@bell_border.to_unsafe) != 0
end

private def needs_attention?(window : Apprt::Window, index : Int32) : Bool
  Apprt::C.adw_tab_page_get_needs_attention(Apprt::C.adw_tab_view_get_nth_page(window.@tab_view, index)) != 0
end

describe Apprt::Bell do
  before_all { GtkHarness.start }

  it "beeps, marks the title and asks for attention by default" do
    app = TestApp.new
    app.bell.should eq Apprt::Bell::System | Apprt::Bell::Attention | Apprt::Bell::Title
  end

  it "clamps the volume" do
    app = TestApp.new
    app.bell_volume.should eq 0.5
    (app.bell_volume = 2.0).should eq 1.0
    app.bell_volume.should eq 1.0
    app.bell_volume = -1.0
    app.bell_volume.should eq 0.0
  end

  it "draws only the border when the bell is Border" do
    run_steps(TestApp.new) do |app|
      app.bell = Apprt::Bell::Border
      window = app.new_window
      first = window.active_surface.not_nil!
      first.title = "shell"
      tab = first.tab.not_nil!
      window.new_tab
      settle
      border_shown?(first).should be_false
      first.ring_bell
      first.bell_ringing?.should be_true
      border_shown?(first).should be_true
      tab.title.should eq "shell"
      needs_attention?(window, 0).should be_false

      first.focus
      eventually { first.focused? }.should be_true
      first.bell_ringing?.should be_false
      border_shown?(first).should be_false
    end
  end

  it "rings without marks when the bell is empty" do
    run_steps(TestApp.new) do |app|
      app.bell = Apprt::Bell::None
      window = app.new_window
      first = window.active_surface.not_nil!
      first.title = "shell"
      tab = first.tab.not_nil!
      window.new_tab
      settle
      first.ring_bell
      tab.title.should eq "shell"
      needs_attention?(window, 0).should be_false
      border_shown?(first).should be_false
    end
  end

  it "plays the bell sound and survives a missing file" do
    run_steps(TestApp.new) do |app|
      app.bell = Apprt::Bell::Audio
      window = app.new_window
      surface = window.active_surface.not_nil!
      surface.ring_bell
      app.@bell_media.null?.should be_true

      # The harness runs without a media backend, so every file fails.
      app.bell_sound = Path["/nonexistent/bell.oga"]
      Log.capture("apprt") do |logs|
        surface.ring_bell
        settle
        logs.check(:warn, /\Abell sound \/nonexistent\/bell\.oga: /)
      end
      app.@bell_media.null?.should be_false
      media = app.@bell_media
      surface.ring_bell
      app.@bell_media.should eq media
    end
  end
end
