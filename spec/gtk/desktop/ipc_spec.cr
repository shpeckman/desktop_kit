# spec/gtk/desktop/ipc_spec.cr
require "../harness"

module IpcSpecs
  Apprt.action Open, "spec-ipc-open", payload: {path: String}, ipc: true
end

class IpcApp < TestApp
  getter opened = [] of String

  protected def perform(target : Apprt::App, action : IpcSpecs::Open) : Bool
    @opened << action.path
    true
  end
end

# Sends *action* to *app_id* from a thread of its own, as another process
# would, and returns where the outcome arrives: `IPC.send` blocks until the
# application answers, which needs the GTK thread free.
private def send_from_thread(app_id : String, action : Apprt::Action) : Channel(Exception?)
  outcome = Channel(Exception?).new(1)
  Fiber::ExecutionContext::Isolated.new("ipc") do
    case action
    when Apprt::Action::NewWindow then Apprt::IPC.send(app_id, action)
    when IpcSpecs::Open           then Apprt::IPC.send(app_id, action)
    end
    outcome.send(nil)
  rescue ex
    outcome.send(ex)
  end
  outcome
end

# Activates the `app` action *name* of *app_id* over D-Bus from a thread of
# its own, bypassing `IPC.send`'s compile-time check.
private def activate_from_thread(app_id : String, name : String) : Channel(Exception?)
  outcome = Channel(Exception?).new(1)
  Fiber::ExecutionContext::Isolated.new("ipc") do
    message = Apprt::Variant.new({name, [] of Apprt::Variant, {} of String => Apprt::Variant})
    bus = Apprt::GLibError.check! { |error| Apprt::C.g_bus_get_sync(Apprt::C::GBusType::Session, Pointer(Void).null, error) }
    reply = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_call_sync(bus, app_id, "/#{app_id.tr(".-", "/_")}", "org.gtk.Actions", "Activate",
        message, Pointer(Void).null, Apprt::C::GDBusCallFlags::None, -1, Pointer(Void).null, error)
    end
    Apprt::C.g_variant_unref(reply)
    Apprt::C.g_object_unref(bus)
    outcome.send(nil)
  rescue ex
    outcome.send(ex)
  end
  outcome
end

# Runs the GTK main loop until *outcome* arrives, and returns it.
private def await(outcome : Channel(Exception?)) : Exception?
  result = nil.as(Exception?)
  received = eventually do
    select
    when value = outcome.receive
      result = value
      true
    else
      false
    end
  end
  received.should be_true
  result
end

describe Apprt::IPC do
  before_all { GtkHarness.start }

  it "triggers an action in the running instance" do
    run_steps(IpcApp.new(single_instance: true)) do |app|
      await(send_from_thread(app.id, Apprt::Action::NewWindow.new)).should be_nil
      eventually { app.windows.size == 1 }.should be_true
    end
  end

  it "sends the action's payload" do
    app = IpcApp.new(single_instance: true)
    run_steps(app) do
      await(send_from_thread(app.id, IpcSpecs::Open.new("/tmp/notes.txt"))).should be_nil
      eventually { app.opened == ["/tmp/notes.txt"] }.should be_true
    end
  end

  it "refuses actions not declared with ipc" do
    run_steps(IpcApp.new(single_instance: true)) do |app|
      window = app.new_window
      error = await(activate_from_thread(app.id, "close-all-windows"))
      error.should be_a(Apprt::GLibError)
      error.not_nil!.message.not_nil!.should contain("Unknown action")
      settle
      window.closed?.should be_false
    end
  end

  it "keeps non-ipc actions working inside the application" do
    run_steps(IpcApp.new(single_instance: true)) do |app|
      window = app.new_window
      Apprt::C.gtk_widget_activate_action_variant(window.@widget, "app.close-all-windows", Pointer(Void).null).should eq 1
      eventually { window.closed? }.should be_true
    end
  end

  it "raises GLibError when no instance runs" do
    expect_raises(Apprt::GLibError) do
      Apprt::IPC.send("org.example.ApprtSpec.Nobody", Apprt::Action::NewWindow.new)
    end
  end

  it "rejects an invalid application id" do
    expect_raises(ArgumentError, %(invalid application id: "no dots")) do
      Apprt::IPC.send("no dots", Apprt::Action::NewWindow.new)
    end
  end
end
