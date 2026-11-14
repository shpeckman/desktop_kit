# spec/gtk/global_shortcuts_spec.cr
require "./fake_portal"

# Records the global bindings the desktop did not bind.
class ShortcutApp < TestApp
  getter failures = [] of {String, String}

  protected def on_binding_failed(binding : Apprt::Binding, message : String) : Nil
    @failures << {binding.trigger.to_s, message}
  end
end

private def xdg(trigger : String) : String
  Apprt::Trigger.parse(trigger).to_xdg
end

private def global_bindings : Array(Apprt::Binding)
  [
    Apprt::Binding.new("ctrl+shift+n", Apprt::Action::NewWindow.new, global: true),
    Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new, global: true),
    Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
  ]
end

describe "Apprt::App global bindings" do
  before_all { GtkHarness.start }

  it "registers the application id with the portal before it runs" do
    FakePortal.serve do |portal|
      app = ShortcutApp.new
      run_steps(app) do
        eventually { portal.registered.includes?(app.id) }.should be_true
      end
      portal.sessions.should be_empty
    end
  end

  it "binds the global bindings and performs their actions on activation" do
    FakePortal.serve do |portal|
      app = ShortcutApp.new
      app.bindings = global_bindings
      run_steps(app) do
        eventually { portal.shortcuts.size == 2 }.should be_true
        portal.shortcuts.should eq [
          FakePortal::Shortcut.new(xdg("ctrl+shift+n"), "app.new-window", xdg("ctrl+shift+n")),
          FakePortal::Shortcut.new(xdg("ctrl+shift+t"), "win.new-tab", xdg("ctrl+shift+t")),
        ]
        portal.activate(xdg("ctrl+shift+n"))
        eventually { app.windows.size == 1 }.should be_true
        portal.activate(xdg("ctrl+shift+t"))
        eventually { app.windows.first.tabs.size == 2 }.should be_true
        app.failures.should be_empty
      end
    end
  end

  it "reports the global bindings the desktop leaves out" do
    FakePortal.serve(deny: [xdg("ctrl+shift+t")]) do
      app = ShortcutApp.new
      app.bindings = global_bindings
      run_steps(app) do
        eventually { app.failures.size == 1 }.should be_true
        app.failures.should eq [{"shift+ctrl+t", "the desktop did not bind the shortcut"}]
      end
    end
  end

  it "reports every global binding when the desktop refuses the request" do
    FakePortal.serve(response: 1_u32) do
      app = ShortcutApp.new
      app.bindings = global_bindings
      run_steps(app) do
        eventually { app.failures.size == 2 }.should be_true
        app.failures.should eq [
          {"shift+ctrl+n", "the request was cancelled"},
          {"shift+ctrl+t", "the request was cancelled"},
        ]
      end
    end
  end

  it "closes the session when the bindings change and at shutdown" do
    FakePortal.serve do |portal|
      app = ShortcutApp.new
      app.bindings = global_bindings
      run_steps(app) do
        eventually { portal.shortcuts.size == 2 }.should be_true
        app.bindings = [] of Apprt::Binding
        eventually { portal.closed.size == 1 }.should be_true
        portal.sessions.size.should eq 1
        app.bindings = global_bindings.first(1)
        eventually { portal.shortcuts.size == 3 }.should be_true
      end
      FakePortal.poll { portal.closed.size == 2 }.should be_true
      portal.closed.should eq portal.sessions
    end
  end

  it "reports the global bindings when no portal runs" do
    app = ShortcutApp.new
    app.bindings = global_bindings
    run_steps(app) do
      eventually { app.failures.size == 2 }.should be_true
      app.failures.map(&.first).should eq ["shift+ctrl+n", "shift+ctrl+t"]
    end
  end
end
