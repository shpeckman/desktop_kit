# spec/gtk/actions/action_spec.cr
require "../harness"

module GtkActionSpecs
  Apprt.action Refresh, "spec-gtk-refresh", payload: {force: Bool}

  Apprt.action Ignored, "spec-gtk-ignored", payload: {text: String}

  Apprt.action Pick, "spec-gtk-pick", payload: {color: Color} do
    enum Color
      Red
      Green
    end
  end
end

private class ActionApp < TestApp
  protected def perform(target : Apprt::App, action : GtkActionSpecs::Refresh) : Bool
    record "refresh #{action.force}"
    true
  end

  protected def perform(target : Apprt::App, action : Apprt::Action::NewWindow) : Bool
    record "new-window"
    true
  end

  protected def on_reload : Nil
    record "reload"
  end
end

private def activate(app : Apprt::App, name : String, parameter : Apprt::Variant? = nil) : Nil
  Apprt::C.g_action_group_activate_action(app.to_unsafe, name, parameter.try(&.to_unsafe) || Pointer(Void).null)
end

private def accels(app : Apprt::App, name : String) : Array(String)
  Apprt::Native.take_strv(Apprt::C.gtk_application_get_accels_for_action(app.to_unsafe, name))
end

describe "Apprt actions" do
  before_all { GtkHarness.start }

  it "installs every application action on the application" do
    app = ActionApp.new
    installed = [] of String
    app.on_activated = ->(app : TestApp) do
      Apprt::Action.registry.each do |info|
        installed << info.name if Apprt::C.g_action_group_has_action(app.to_unsafe, info.name) != 0
      end
      app.quit
    end
    run_app(app).should eq 0
    installed.should eq Apprt::Action.registry.select(&.scope.app?).map(&.name)
  end

  it "performs activated actions with their payload" do
    app = ActionApp.new
    app.on_activated = ->(app : TestApp) do
      activate(app, "spec-gtk-refresh", Apprt::Variant.new(true))
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
      activate(app, "spec-gtk-ignored", Apprt::Variant.new("x"))
      activate(app, "spec-gtk-pick", Apprt::Variant.new("purple"))
      app.quit
    end
    Log.capture("apprt") do |logs|
      run_app(app).should eq 0
      logs.check(:warn, "action app.spec-gtk-ignored::x not handled")
      logs.check(:warn, /\Aaction app\.spec-gtk-pick: invalid parameter /)
    end
  end

  it "closes the application windows on close-all-windows" do
    app = ActionApp.new
    windows = -1
    app.on_activated = ->(app : TestApp) do
      Apprt::C.gtk_window_present(Apprt::C.adw_application_window_new(app.to_unsafe))
      activate(app, "close-all-windows")
      windows = 0
      Apprt::Native.each(Apprt::C.gtk_application_get_windows(app.to_unsafe)) { windows += 1 }
      app.quit
    end
    run_app(app).should eq 0
    windows.should eq 0
  end

  it "applies the local bindings as accelerators and replaces them" do
    app = ActionApp.new
    app.bindings = [
      Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
      Apprt::Binding.new("ctrl+shift+q", Apprt::Action::Quit.new),
      Apprt::Binding.new("ctrl+shift+e", Apprt::Action::NewSplit.new(:right)),
      Apprt::Binding.new("ctrl+q", Apprt::Action::CloseAllWindows.new),
      Apprt::Binding.new("ctrl+n", Apprt::Action::NewWindow.new, global: true),
    ]
    before = {} of String => Array(String)
    after = {} of String => Array(String)
    names = {"app.quit", "split.new-split::right", "app.close-all-windows", "app.new-window", "app.reload-config"}
    app.on_activated = ->(app : TestApp) do
      names.each { |name| before[name] = accels(app, name) }
      app.bindings = [Apprt::Binding.new("ctrl+r", Apprt::Action::ReloadConfig.new)]
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
