# spec/gtk/window/logout_inhibit_spec.cr
require "../fake_bus_service"

# GtkApplicationInhibitFlags::Logout.
private LOGOUT = 1_u32

# `org.gnome.SessionManager`, which GTK asks to inhibit logging out when it
# uses no portals (as the harness sets).
private class FakeSessionManager < FakeBusService
  # One `Inhibit` call: the app id, flags and reason it passed.
  record Inhibition, app_id : String, flags : UInt32, reason : String

  NAME = "org.gnome.SessionManager"
  PATH = "/org/gnome/SessionManager"

  @inhibitions = [] of Inhibition
  @uninhibited = [] of UInt32

  def initialize
    super(NAME)
  end

  # Runs the block with a session manager on the bus.
  def self.serve(& : FakeSessionManager ->) : Nil
    manager = new
    begin
      yield manager
    ensure
      manager.stop
    end
  end

  # Returns the `Inhibit` calls in order; each got its index + 1 as cookie.
  def inhibitions : Array(Inhibition)
    @lock.synchronize { @inhibitions.dup }
  end

  # Returns the cookies passed to `Uninhibit`, in order.
  def uninhibited : Array(UInt32)
    @lock.synchronize { @uninhibited.dup }
  end

  private def xml : String
    <<-XML
      <node>
        <interface name="org.gnome.SessionManager">
          <method name="Inhibit">
            <arg type="s" direction="in"/>
            <arg type="u" direction="in"/>
            <arg type="s" direction="in"/>
            <arg type="u" direction="in"/>
            <arg type="u" direction="out"/>
          </method>
          <method name="Uninhibit">
            <arg type="u" direction="in"/>
          </method>
        </interface>
      </node>
      XML
  end

  private def start_service : Nil
    export(PATH, NAME)
  end

  protected def call(sender : String, path : String, interface : String, method : String, parameters : DesktopKit::Variant, invocation : Void*) : Nil
    case method
    when "Inhibit"
      cookie = @lock.synchronize do
        @inhibitions << Inhibition.new(parameters[0].get(String), parameters[3].get(UInt32), parameters[2].get(String))
        @inhibitions.size.to_u32
      end
      reply(invocation, DesktopKit::Variant.new({cookie}))
    when "Uninhibit"
      @lock.synchronize { @uninhibited << parameters[0].get(UInt32) }
      reply(invocation, nil)
    end
  end
end

# Splits the active surface to the right and returns the new surface.
private def split(window : DesktopKit::Window) : DesktopKit::Surface
  trigger(window, DesktopKit::Action::NewSplit.new(:right))
  window.active_surface.not_nil!
end

describe "App#logout_inhibited?" do
  before_all { GtkHarness.start }

  it "inhibits logging out while a surface asks before closing" do
    FakeSessionManager.serve do |manager|
      app = TestApp.new
      run_steps(app) do
        window = app.new_window
        surface = window.active_surface.not_nil!
        app.logout_inhibited?.should be_false
        surface.confirm_close = true
        app.logout_inhibited?.should be_true
        eventually { manager.inhibitions.size == 1 }.should be_true
        inhibition = manager.inhibitions.first
        inhibition.app_id.should eq app.id
        inhibition.flags.should eq LOGOUT
        inhibition.reason.should eq "Some windows ask before closing"
        other = split(window)
        other.confirm_close = true
        surface.confirm_close = false
        app.logout_inhibited?.should be_true
        other.confirm_close = false
        app.logout_inhibited?.should be_false
        eventually { manager.uninhibited == [1_u32] }.should be_true
        manager.inhibitions.size.should eq 1
      end
    end
  end

  it "lifts the inhibition when the asking surface closes" do
    FakeSessionManager.serve do |manager|
      app = TestApp.new
      run_steps(app) do
        window = app.new_window
        window.active_surface.not_nil!.confirm_close = true
        other = split(window)
        app.logout_inhibited?.should be_true
        other.close
        app.logout_inhibited?.should be_true
        surface = window.active_surface.not_nil!
        surface.close
        dialog = DesktopKit::C.adw_application_window_get_visible_dialog(window.widget)
        dialog.null?.should be_false
        DesktopKit::C.adw_alert_dialog_set_close_response(dialog, "ok")
        DesktopKit::C.adw_dialog_force_close(dialog)
        eventually { surface.closed? }.should be_true
        app.logout_inhibited?.should be_false
        eventually { manager.uninhibited.size == 1 }.should be_true
      end
    end
  end

  it "lifts the inhibition when the app quits" do
    FakeSessionManager.serve do |manager|
      app = TestApp.new
      run_steps(app) do
        app.new_window.active_surface.not_nil!.confirm_close = true
        app.logout_inhibited?.should be_true
        eventually { manager.inhibitions.size == 1 }.should be_true
      end
      app.logout_inhibited?.should be_false
      FakeBusService.poll { manager.uninhibited.size == 1 }.should be_true
    end
  end
end
