# spec/gtk/desktop/dbus_spec.cr
require "../harness"

describe Apprt::DBus do
  before_all { GtkHarness.start }

  it "calls methods synchronously and asynchronously" do
    app = TestApp.new
    run_steps(app) do
      bus = app.dbus.should_not be_nil
      bus.unique_name.should start_with(":")
      names = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames",
        reply_type: "(as)")
      names[0].get(Array(String)).should contain(bus.unique_name)

      reply = nil.as(Apprt::Variant?)
      failure = nil.as(Apprt::GLibError?)
      done = false
      bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
        Apprt::Variant.new({"org.freedesktop.DBus"})) do |value, error|
        reply, failure, done = value, error, true
      end
      eventually { done }.should be_true
      failure.should be_nil
      reply.not_nil![0].get(String).should eq("org.freedesktop.DBus")

      done = false
      bus.call("org.example.Nobody", "/", "org.example.Nobody", "Hello", auto_start: false) do |value, error|
        reply, failure, done = value, error, true
      end
      eventually { done }.should be_true
      reply.should be_nil
      failure.should_not be_nil
    end
  end

  it "emits signals to its subscribers" do
    app = TestApp.new
    run_steps(app) do
      bus = Apprt::DBus.session
      received = [] of Apprt::DBus::Signal
      subscription = bus.subscribe(interface: "org.example.Spec", member: "Ping") { |signal| received << signal }
      bus.emit("/org/example/spec", "org.example.Spec", "Ping", Apprt::Variant.new({42_u32}))
      eventually { received.size == 1 }.should be_true
      signal = received.first
      signal.sender.should eq(bus.unique_name)
      signal.path.should eq("/org/example/spec")
      signal.args[0].get(UInt32).should eq(42)
      subscription.cancel
      subscription.active?.should be_false
      bus.emit("/org/example/spec", "org.example.Spec", "Ping", Apprt::Variant.new({43_u32}))
      settle
      received.size.should eq(1)
      expect_raises(ArgumentError) { bus.emit("/", "org.example.Spec", "Ping", Apprt::Variant.new(1)) }
    end
  end
end
