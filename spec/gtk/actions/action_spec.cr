# spec/gtk/actions/action_spec.cr
require "../harness"

module GtkActionSpecs
  DesktopKit.action Refresh, "spec-gtk-refresh", payload: {force: Bool}

  DesktopKit.action Ignored, "spec-gtk-ignored", payload: {text: String}

  DesktopKit.action Pick, "spec-gtk-pick", payload: {color: Color} do
    # Not file-private: the `Variant` macro expansion must see it.
    enum Color
      Red
      Green
    end
  end
end

private class ActionApp < TestApp
  protected def perform(target : DesktopKit::App, action : GtkActionSpecs::Refresh) : Bool
    record "refresh #{action.force}"
    true
  end

  protected def perform(target : DesktopKit::App, action : DesktopKit::Action::NewWindow) : Bool
    record "new-window"
    true
  end

  protected def on_reload : Nil
    record "reload"
  end
end

# Activates the `app` action *name* as a window would.
private def activate(app : DesktopKit::App, name : String, parameter : DesktopKit::Variant? = nil) : Nil
  DesktopKit::C.g_action_group_activate_action(app.@actions, name, parameter.try(&.to_unsafe) || Pointer(Void).null)
end

private def accels(app : DesktopKit::App, name : String) : Array(String)
  DesktopKit::Native.take_strv(DesktopKit::C.gtk_application_get_accels_for_action(app.to_unsafe, name))
end

describe "DesktopKit actions" do
  before_all { GtkHarness.start }

  it "installs every application action for windows and exports the ipc ones" do
    app = ActionApp.new
    installed = [] of String
    exported = [] of String
    app.on_activated = ->(app : TestApp) do
      DesktopKit::Action.registry.each do |info|
        installed << info.name if DesktopKit::C.g_action_group_has_action(app.@actions, info.name) != 0
        exported << info.name if DesktopKit::C.g_action_group_has_action(app.to_unsafe, info.name) != 0
      end
      app.quit
    end
    run_app(app).should eq 0
    installed.should eq DesktopKit::Action.registry.select(&.scope.app?).map(&.name)
    exported.should eq DesktopKit::Action.registry.select { |info| info.scope.app? && info.ipc }.map(&.name)
    exported.should_not be_empty
    exported.size.should be < installed.size
  end

  it "performs activated actions with their payload" do
    app = ActionApp.new
    app.on_activated = ->(app : TestApp) do
      activate(app, "spec-gtk-refresh", DesktopKit::Variant.new(true))
      activate(app, "new-window")
      activate(app, "reload-config")
      activate(app, "quit")
    end
    run_app(app).should eq 0
    app.events.should eq ["startup", "scheme light", "activate", "refresh true", "new-window", "reload", "shutdown"]
  end

  it "warns about actions it does not handle or cannot decode" do
    app = ActionApp.new
    app.on_activated = ->(app : TestApp) do
      activate(app, "spec-gtk-ignored", DesktopKit::Variant.new("x"))
      activate(app, "spec-gtk-pick", DesktopKit::Variant.new("purple"))
      app.quit
    end
    Log.capture("desktop_kit") do |logs|
      run_app(app).should eq 0
      logs.check(:warn, "action app.spec-gtk-ignored::x not handled")
      logs.check(:warn, /\Aaction app\.spec-gtk-pick: invalid parameter /)
    end
  end

  it "closes the application windows on close-all-windows" do
    app = ActionApp.new
    windows = -1
    app.on_activated = ->(app : TestApp) do
      DesktopKit::C.gtk_window_present(DesktopKit::C.adw_application_window_new(app.to_unsafe))
      activate(app, "close-all-windows")
      windows = 0
      DesktopKit::Native.each(DesktopKit::C.gtk_application_get_windows(app.to_unsafe)) { windows += 1 }
      app.quit
    end
    run_app(app).should eq 0
    windows.should eq 0
  end

  it "applies the local bindings as accelerators and replaces them" do
    app = ActionApp.new
    app.bindings = [
      DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::Quit.new),
      DesktopKit::Binding.new("ctrl+shift+q", DesktopKit::Action::Quit.new),
      DesktopKit::Binding.new("ctrl+shift+e", DesktopKit::Action::NewSplit.new(:right)),
      DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::CloseAllWindows.new),
      DesktopKit::Binding.new("ctrl+n", DesktopKit::Action::NewWindow.new, global: true),
    ]
    before = {} of String => Array(String)
    after = {} of String => Array(String)
    names = {"app.quit", "split.new-split::right", "app.close-all-windows", "app.new-window", "app.reload-config"}
    app.on_activated = ->(app : TestApp) do
      names.each { |name| before[name] = accels(app, name) }
      app.bindings = [DesktopKit::Binding.new("ctrl+r", DesktopKit::Action::ReloadConfig.new)]
      names.each { |name| after[name] = accels(app, name) }
      app.quit
    end
    run_app(app).should eq 0
    before.should eq({
      "app.quit"               => ["<Control>q", "<Shift><Control>q"],
      "split.new-split::right" => ["<Shift><Control>e"],
      "app.close-all-windows"  => [] of String,
      "app.new-window"         => [] of String,
      "app.reload-config"      => [] of String,
    })
    after.should eq({
      "app.quit"               => [] of String,
      "split.new-split::right" => [] of String,
      "app.close-all-windows"  => [] of String,
      "app.new-window"         => [] of String,
      "app.reload-config"      => ["<Control>r"],
    })
    app.bindings.size.should eq 1
  end
end
