# spec/gtk/actions/key_table_spec.cr
require "../harness"

lib KeyTableSpecLib
  fun gtk_label_get_label(label : Void*) : UInt8*
end

private CTRL = 4_u32 # GDK_CONTROL_MASK

# Presses *keyval* with *state* on the window's key controller and returns
# whether the window took the key.
private def press(window : DesktopKit::Window, key : Char, state : UInt32 = 0_u32) : Bool
  result = 0
  DesktopKit::C.g_signal_emit_by_name(window.@sequence_keys, "key-pressed", key.ord.to_u32, 0_u32, state, pointerof(result))
  settle
  result != 0
end

# The text of the window's key state overlay, or nil while it is hidden.
private def key_state(window : DesktopKit::Window) : String?
  label = window.@key_state
  String.new(KeyTableSpecLib.gtk_label_get_label(label)) if label.visible?
end

private TABLES = {
  "tabs" => [
    DesktopKit::Binding.new("n", DesktopKit::Action::NewTab.new),
    DesktopKit::Binding.new("g>c", DesktopKit::Action::CloseTab.new(:this)),
    DesktopKit::Binding.new("q", DesktopKit::Action::DeactivateKeyTable.new),
  ],
  "splits" => [DesktopKit::Binding.new("s", DesktopKit::Action::NewSplit.new(:right))],
}

describe "key tables" do
  before_all { GtkHarness.start }

  it "takes the table's keys until it is deactivated" do
    app = TestApp.new
    run_steps(app) do
      app.key_tables = TABLES
      window = app.new_window
      settle
      press(window, 'n').should be_false
      key_state(window).should be_nil
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("tabs"))
      window.key_tables.should eq ["tabs"]
      key_state(window).should eq "tabs"
      press(window, 'n').should be_true
      press(window, 'n').should be_true
      window.tabs.size.should eq 3
      press(window, 'x').should be_false
      press(window, 'q').should be_true
      window.key_tables.should be_empty
      key_state(window).should be_nil
      press(window, 'n').should be_false
      window.tabs.size.should eq 3
    end
  end

  it "follows sequences inside a table and shows the pending keys" do
    app = TestApp.new
    run_steps(app) do
      app.key_tables = TABLES
      window = app.new_window
      settle
      trigger(window, DesktopKit::Action::NewTab.new)
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("tabs"))
      press(window, 'g').should be_true
      key_state(window).should eq "tabs › G"
      press(window, 'c').should be_true
      window.tabs.size.should eq 1
      key_state(window).should eq "tabs"
    end
  end

  it "searches the innermost table first and the bindings last" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewSplit.new(:down))]
      app.key_tables = TABLES
      window = app.new_window
      settle
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("tabs"))
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("splits"))
      window.key_tables.should eq ["tabs", "splits"]
      key_state(window).should eq "tabs › splits"
      press(window, 's').should be_true
      press(window, 'n').should be_true
      window.tabs.size.should eq 2
      press(window, 'a', CTRL).should be_true
      press(window, 'n').should be_true
      window.active_tab.not_nil!.surfaces.size.should eq 2
      trigger(window, DesktopKit::Action::DeactivateAllKeyTables.new)
      window.key_tables.should be_empty
    end
  end

  it "drops a table activated once after its first binding" do
    app = TestApp.new
    run_steps(app) do
      app.key_tables = TABLES
      window = app.new_window
      settle
      trigger(window, DesktopKit::Action::ActivateKeyTableOnce.new("tabs"))
      window.key_tables.should eq ["tabs"]
      press(window, 'x').should be_false
      press(window, 'n').should be_true
      window.key_tables.should be_empty
      press(window, 'n').should be_false
      window.tabs.size.should eq 2
    end
  end

  it "ignores unknown tables, repeats and more than eight" do
    app = TestApp.new
    run_steps(app) do
      app.key_tables = TABLES
      window = app.new_window
      settle
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("missing"))
      window.key_tables.should be_empty
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("tabs"))
      trigger(window, DesktopKit::Action::ActivateKeyTable.new("tabs"))
      window.key_tables.should eq ["tabs"]
      9.times do |index|
        trigger(window, DesktopKit::Action::ActivateKeyTable.new(index.even? ? "splits" : "tabs"))
      end
      window.key_tables.size.should eq 8
    end
  end

  it "rejects global bindings" do
    app = TestApp.new
    expect_raises(ArgumentError, "key table t: binding ctrl+n cannot be global") do
      app.key_tables = {"t" => [DesktopKit::Binding.new("ctrl+n", DesktopKit::Action::NewTab.new, global: true)]}
    end
  end
end
