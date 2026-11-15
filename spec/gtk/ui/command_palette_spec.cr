# spec/gtk/ui/command_palette_spec.cr
require "../harness"

private def palette(window : Apprt::Window) : Apprt::CommandPalette
  window.@palette.not_nil!
end

private def search(palette : Apprt::CommandPalette, text : String) : Nil
  Apprt::C.gtk_editable_set_text(palette.@entry, text)
  eventually { palette.query == text }.should be_true
  settle
end

describe "command palette" do
  before_all { GtkHarness.start }

  it "opens over the window and closes again" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ToggleCommandPalette.new)
      palette = palette(window)
      Apprt::C.adw_application_window_get_visible_dialog(window.widget).should eq palette.dialog.to_unsafe
      palette.shown.map(&.title).should eq Apprt::Command.defaults.map(&.title)
      trigger(window, Apprt::Action::ToggleCommandPalette.new)
      palette.closed?.should be_true
    end
  end

  it "filters the commands and performs the selected one" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ToggleCommandPalette.new)
      palette = palette(window)
      search(palette, "split right")
      palette.shown.map(&.title).should eq ["Split Right"]
      palette.selected.try(&.title).should eq "Split Right"
      palette.activate
      settle
      palette.closed?.should be_true
      window.tabs.first.surfaces.size.should eq 2
    end
  end

  it "moves the selection over the shown rows" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ToggleCommandPalette.new)
      palette = palette(window)
      search(palette, "tab")
      shown = palette.shown.map(&.title)
      shown.size.should be > 2
      palette.selected.try(&.title).should eq shown[0]
      palette.move(1)
      palette.selected.try(&.title).should eq shown[1]
      palette.move(-5)
      palette.selected.try(&.title).should eq shown[0]
      palette.move(100)
      palette.selected.try(&.title).should eq shown.last
      search(palette, "nothing matches this")
      palette.shown.should be_empty
      palette.selected.should be_nil
      palette.activate
      settle
      palette.closed?.should be_true
      window.tabs.size.should eq 1
    end
  end

  it "lists the application's commands" do
    app = TestApp.new
    app.commands = [Apprt::Command.new("Open Tab", Apprt::Action::NewTab.new)]
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ToggleCommandPalette.new)
      palette = palette(window)
      palette.shown.map(&.title).should eq ["Open Tab"]
      palette.activate
      settle
      window.tabs.size.should eq 2
    end
  end
end
