# spec/gtk/ui/shortcuts_spec.cr
require "../harness"

private def shortcuts(window : Apprt::Window) : Apprt::ShortcutsDialog
  window.@shortcuts_dialog.not_nil!
end

describe "keyboard shortcuts dialog" do
  before_all { GtkHarness.start }

  it "lists the bindings per scope and key table" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [
        Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new),
        Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
        Apprt::Binding.new("ctrl+a>r", Apprt::Action::NewSplit.new(:right)),
        Apprt::Binding.new("ctrl+alt+o", Apprt::Action::ResizeSplit.new(:up, 10_u32)),
      ]
      app.key_tables = {"resize" => [Apprt::Binding.new("escape", Apprt::Action::DeactivateKeyTable.new)]}
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ShowShortcuts.new)
      dialog = shortcuts(window)
      Apprt::C.adw_application_window_get_visible_dialog(window.widget).should eq dialog.dialog.to_unsafe
      dialog.groups.map(&.[0]).should eq ["Application", "Window", "Split", "resize"]
      groups = dialog.groups.to_h
      groups["Application"].map { |entry| {entry.title, entry.shortcut} }.should eq [{"Quit", "Ctrl+Q"}]
      groups["Window"].map(&.title).should eq ["New Tab"]
      groups["Split"].map { |entry| {entry.title, entry.shortcut} }.should eq [
        {"Split Right", "Ctrl+A R"}, {"Resize split (up, 10)", "Ctrl+Alt+O"},
      ]
      groups["resize"].map(&.title).should eq ["Deactivate key table"]
    end
  end

  it "replaces an open dialog" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new)]
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ShowShortcuts.new)
      first = shortcuts(window)
      trigger(window, Apprt::Action::ShowShortcuts.new)
      first.closed?.should be_true
      shortcuts(window).should_not be(first)
      shortcuts(window).closed?.should be_false
    end
  end
end
