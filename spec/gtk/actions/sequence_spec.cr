# spec/gtk/actions/sequence_spec.cr
require "../harness"

private CTRL = 4_u32 # GDK_CONTROL_MASK

# Presses *keyval* with *state* on the window's sequence controller and
# returns whether the window took the key.
private def press(window : DesktopKit::Window, keyval : Char | UInt32, state : UInt32 = 0_u32) : Bool
  code = keyval.is_a?(Char) ? keyval.ord.to_u32 : keyval
  result = 0
  DesktopKit::C.g_signal_emit_by_name(window.@sequence_keys, "key-pressed", code, 0_u32, state, pointerof(result))
  settle
  result != 0
end

describe "key sequences" do
  before_all { GtkHarness.start }

  it "performs the action once the sequence completes" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [
        DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewTab.new),
        DesktopKit::Binding.new("ctrl+a>ctrl+b>s", DesktopKit::Action::NewSplit.new(:right)),
      ]
      window = app.new_window
      settle
      press(window, 'a', CTRL).should be_true
      window.tabs.size.should eq 1
      press(window, 'n').should be_true
      window.tabs.size.should eq 2
      press(window, 'a', CTRL).should be_true
      press(window, 'b', CTRL).should be_true
      press(window, 's').should be_true
      window.active_tab.not_nil!.surfaces.size.should eq 2
    end
  end

  it "ends the sequence on another key and drops that key" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewTab.new)]
      window = app.new_window
      settle
      press(window, 'x').should be_false
      press(window, 'a', CTRL).should be_true
      press(window, 'x').should be_true
      press(window, 'n').should be_false
      window.tabs.size.should eq 1
    end
  end

  it "ends the sequence after the sequence timeout" do
    app = TestApp.new
    run_steps(app) do
      app.sequence_timeout = 400.milliseconds
      app.bindings = [DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewTab.new)]
      window = app.new_window
      settle
      press(window, 'a', CTRL).should be_true
      window.@sequence.empty?.should be_false
      eventually { window.@sequence.empty? }.should be_true
      press(window, 'n').should be_false
      window.tabs.size.should eq 1
      press(window, 'a', CTRL).should be_true
      press(window, 'n').should be_true
      window.tabs.size.should eq 2
    end
  end

  it "waits for the next key without a sequence timeout" do
    app = TestApp.new
    run_steps(app) do
      app.sequence_timeout.should be_nil
      app.bindings = [DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewTab.new)]
      window = app.new_window
      settle
      press(window, 'a', CTRL).should be_true
      settle(300.milliseconds)
      press(window, 'n').should be_true
      window.tabs.size.should eq 2
    end
  end

  it "ignores modifier keys while waiting" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [DesktopKit::Binding.new("ctrl+a>shift+n", DesktopKit::Action::NewTab.new)]
      window = app.new_window
      settle
      press(window, 'a', CTRL).should be_true
      press(window, 'N', 1_u32).should be_true # GDK_SHIFT_MASK
      window.tabs.size.should eq 2
    end
  end

  it "lets keys through without sequences" do
    app = TestApp.new
    run_steps(app) do
      app.bindings = [DesktopKit::Binding.new("ctrl+t", DesktopKit::Action::NewTab.new)]
      window = app.new_window
      settle
      press(window, 'a', CTRL).should be_false
      press(window, 't', CTRL).should be_false
    end
  end
end
