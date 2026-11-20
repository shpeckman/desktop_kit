# spec/gtk/desktop/tray_spec.cr
require "../fake_bus_service"

# `org.kde.StatusNotifierWatcher`, recording the items registered with it.
private class FakeWatcher < FakeBusService
  NAME = "org.kde.StatusNotifierWatcher"
  PATH = "/StatusNotifierWatcher"

  @items = [] of String

  def initialize
    super(NAME)
  end

  # Runs the block with a watcher on the bus.
  def self.serve(& : FakeWatcher ->) : Nil
    watcher = new
    begin
      yield watcher
    ensure
      watcher.stop
    end
  end

  # Returns the service names passed to `RegisterStatusNotifierItem`.
  def items : Array(String)
    @lock.synchronize { @items.dup }
  end

  private def xml : String
    <<-XML
      <node>
        <interface name="org.kde.StatusNotifierWatcher">
          <method name="RegisterStatusNotifierItem">
            <arg type="s" direction="in"/>
          </method>
        </interface>
      </node>
      XML
  end

  private def start_service : Nil
    export(PATH, NAME)
  end

  protected def call(sender : String, path : String, interface : String, method : String, parameters : DesktopKit::Variant, invocation : Void*) : Nil
    @lock.synchronize { @items << parameters[0].get(String) }
    reply(invocation, nil)
  end
end

private ITEM = "org.kde.StatusNotifierItem"
private MENU = "com.canonical.dbusmenu"

# Calls *method* on the app's own tray object at *path* and returns the
# reply, or raises the error. Asynchronous: a synchronous call from the GTK
# thread would wait for itself.
private def tray_call(app : TestApp, path : String, interface : String, method : String, args : DesktopKit::Variant? = nil) : DesktopKit::Variant?
  bus = app.dbus.not_nil!
  result = nil.as(DesktopKit::Variant?)
  failure = nil.as(DesktopKit::GLibError?)
  done = false
  bus.call(bus.unique_name, path, interface, method, args) do |reply, error|
    result, failure, done = reply, error, true
  end
  eventually { done }.should be_true
  failure.try { |ex| raise ex }
  result
end

private def tray_property(app : TestApp, path : String, interface : String, name : String) : DesktopKit::Variant
  tray_call(app, path, "org.freedesktop.DBus.Properties", "Get", DesktopKit::Variant.new({interface, name})).not_nil![0].get(DesktopKit::Variant)
end

# Returns the menu layout as `{id, label or type, children}` tuples.
private def menu_layout(app : TestApp) : String
  reply = tray_call(app, "/MenuBar", MENU, "GetLayout", DesktopKit::Variant.new({0, -1, [] of String})).not_nil!
  describe_node(reply[1])
end

private def describe_node(node : DesktopKit::Variant) : String
  properties = node[1]
  name = properties["label"]?.try(&.get(String)) || properties["type"]?.try(&.get(String)) || "root"
  children = node[2]
  return name if children.size == 0
  "#{name}[#{(0...children.size).map { |index| describe_node(children[index].get(DesktopKit::Variant)) }.join(", ")}]"
end

private def tray_menu : DesktopKit::Menu
  DesktopKit::Menu.build do |menu|
    menu.item "New_Window", DesktopKit::Action::NewWindow.new
    menu.submenu "More" do |more|
      more.item "Close All", DesktopKit::Action::CloseAllWindows.new
    end
    menu.section
    menu.item "Quit", DesktopKit::Action::Quit.new
  end
end

describe "App#tray=" do
  before_all { GtkHarness.start }

  it "registers the item and shows its properties" do
    FakeWatcher.serve do |watcher|
      app = TestApp.new
      run_steps(app) do
        app.new_window
        app.tray = DesktopKit::Tray.new(icon: "mail-unread-symbolic", title: "Mail", tooltip: "3 new", menu: tray_menu)
        eventually { watcher.items == [app.dbus.not_nil!.unique_name] }.should be_true
        tray_property(app, "/StatusNotifierItem", ITEM, "Id").get(String).should eq app.id
        tray_property(app, "/StatusNotifierItem", ITEM, "Title").get(String).should eq "Mail"
        tray_property(app, "/StatusNotifierItem", ITEM, "IconName").get(String).should eq "mail-unread-symbolic"
        tray_property(app, "/StatusNotifierItem", ITEM, "ItemIsMenu").get(Bool).should be_true
        tray_property(app, "/StatusNotifierItem", ITEM, "Menu").to_s.should eq "'/MenuBar'"
        tooltip = tray_property(app, "/StatusNotifierItem", ITEM, "ToolTip")
        tooltip.type_string.should eq "(sa(iiay)ss)"
        tooltip[2].get(String).should eq "Mail"
        tooltip[3].get(String).should eq "3 new"
      end
    end
  end

  it "registers once a watcher appears" do
    app = TestApp.new
    run_steps(app) do
      app.new_window
      app.tray = DesktopKit::Tray.new(icon: "mail-symbolic", title: "Mail")
      settle
      FakeWatcher.serve do |watcher|
        eventually { watcher.items == [app.dbus.not_nil!.unique_name] }.should be_true
      end
    end
  end

  it "exports the menu and performs clicked items" do
    app = TestApp.new
    run_steps(app) do
      app.new_window
      app.tray = DesktopKit::Tray.new(icon: "mail-symbolic", title: "Mail", menu: tray_menu)
      menu_layout(app).should eq "root[New__Window, More[Close All], separator, Quit]"
      tray_call(app, "/MenuBar", MENU, "Event", DesktopKit::Variant.new({1, "clicked", DesktopKit::Variant.new(""), 0_u32}))
      eventually { app.windows.size == 2 }.should be_true
      errors = tray_call(app, "/MenuBar", MENU, "EventGroup",
        DesktopKit::Variant.parse("([(1, 'clicked', <''>, uint32 0), (99, 'clicked', <''>, uint32 0)],)")).not_nil!
      errors[0].get(Array(Int32)).should eq [99]
      eventually { app.windows.size == 3 }.should be_true
      expect_raises(DesktopKit::GLibError) { tray_call(app, "/MenuBar", MENU, "GetLayout", DesktopKit::Variant.new({99, -1, [] of String})) }
    end
  end

  it "performs the activate action on a primary click" do
    app = TestApp.new
    run_steps(app) do
      app.new_window
      app.tray = DesktopKit::Tray.new(icon: "mail-symbolic", title: "Mail", activate: DesktopKit::Action::NewWindow.new)
      tray_property(app, "/StatusNotifierItem", ITEM, "ItemIsMenu").get(Bool).should be_false
      tray_call(app, "/StatusNotifierItem", ITEM, "Activate", DesktopKit::Variant.new({0, 0}))
      eventually { app.windows.size == 2 }.should be_true
    end
  end

  it "updates and removes the item" do
    app = TestApp.new
    run_steps(app) do
      app.new_window
      app.tray = DesktopKit::Tray.new(icon: "mail-symbolic", title: "Mail", menu: tray_menu)
      revision = tray_call(app, "/MenuBar", MENU, "GetLayout", DesktopKit::Variant.new({0, 0, [] of String})).not_nil![0].get(UInt32)
      app.tray = DesktopKit::Tray.new(icon: "mail-unread-symbolic", title: "Mail (1)",
        menu: DesktopKit::Menu.build { |menu| menu.item "Quit", DesktopKit::Action::Quit.new })
      tray_property(app, "/StatusNotifierItem", ITEM, "Title").get(String).should eq "Mail (1)"
      tray_property(app, "/StatusNotifierItem", ITEM, "IconName").get(String).should eq "mail-unread-symbolic"
      menu_layout(app).should eq "root[Quit]"
      tray_call(app, "/MenuBar", MENU, "GetLayout", DesktopKit::Variant.new({0, 0, [] of String})).not_nil![0].get(UInt32).should be > revision
      app.tray = nil
      app.tray.should be_nil
      expect_raises(DesktopKit::GLibError) { tray_property(app, "/StatusNotifierItem", ITEM, "Title") }
    end
  end
end
