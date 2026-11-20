# src/desktop_kit/desktop/tray.cr
module DesktopKit
  # A status icon in the desktop's system tray: an *icon* name from the
  # icon theme, a *title*, an optional *tooltip* text, a *menu* the tray
  # shows on click and an *activate* action performed on a primary click.
  # Without *activate* a primary click shows the menu too.
  #
  # ```
  # app.tray = DesktopKit::Tray.new(icon: "mail-unread-symbolic", title: "Mail",
  #   menu: DesktopKit::Menu.build { |menu| menu.item "Quit", DesktopKit::Action::Quit.new },
  #   activate: DesktopKit::Action::NewWindow.new)
  # ```
  record Tray, icon : String, title : String, tooltip : String? = nil, menu : Menu? = nil, activate : Action? = nil

  # :nodoc:
  # Shows a `Tray` as a StatusNotifierItem (`/StatusNotifierItem`) with its
  # menu as a `com.canonical.dbusmenu` (`/MenuBar`) on the application's
  # connection, and registers it with the `org.kde.StatusNotifierWatcher`
  # whenever one appears. Menu items get ids in preorder, 0 being the root;
  # a separator node sits between non-empty sections. Every menu change
  # bumps the layout revision. Runs on the GTK thread.
  class StatusNotifier
    ITEM         = "org.kde.StatusNotifierItem"
    ITEM_PATH    = "/StatusNotifierItem"
    MENU         = "com.canonical.dbusmenu"
    MENU_PATH    = "/MenuBar"
    WATCHER      = "org.kde.StatusNotifierWatcher"
    WATCHER_PATH = "/StatusNotifierWatcher"

    private XML = <<-XML
      <node>
        <interface name="org.kde.StatusNotifierItem">
          <property name="Category" type="s" access="read"/>
          <property name="Id" type="s" access="read"/>
          <property name="Title" type="s" access="read"/>
          <property name="Status" type="s" access="read"/>
          <property name="WindowId" type="i" access="read"/>
          <property name="IconName" type="s" access="read"/>
          <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
          <property name="ItemIsMenu" type="b" access="read"/>
          <property name="Menu" type="o" access="read"/>
          <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
          <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
          <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
          <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
          <signal name="NewTitle"/>
          <signal name="NewIcon"/>
          <signal name="NewToolTip"/>
          <signal name="NewStatus"><arg name="status" type="s"/></signal>
        </interface>
        <interface name="com.canonical.dbusmenu">
          <property name="Version" type="u" access="read"/>
          <property name="TextDirection" type="s" access="read"/>
          <property name="Status" type="s" access="read"/>
          <property name="IconThemePath" type="as" access="read"/>
          <method name="GetLayout">
            <arg name="parentId" type="i" direction="in"/>
            <arg name="recursionDepth" type="i" direction="in"/>
            <arg name="propertyNames" type="as" direction="in"/>
            <arg name="revision" type="u" direction="out"/>
            <arg name="layout" type="(ia{sv}av)" direction="out"/>
          </method>
          <method name="GetGroupProperties">
            <arg name="ids" type="ai" direction="in"/>
            <arg name="propertyNames" type="as" direction="in"/>
            <arg name="properties" type="a(ia{sv})" direction="out"/>
          </method>
          <method name="GetProperty">
            <arg name="id" type="i" direction="in"/>
            <arg name="name" type="s" direction="in"/>
            <arg name="value" type="v" direction="out"/>
          </method>
          <method name="Event">
            <arg name="id" type="i" direction="in"/>
            <arg name="eventId" type="s" direction="in"/>
            <arg name="data" type="v" direction="in"/>
            <arg name="timestamp" type="u" direction="in"/>
          </method>
          <method name="EventGroup">
            <arg name="events" type="a(isvu)" direction="in"/>
            <arg name="idErrors" type="ai" direction="out"/>
          </method>
          <method name="AboutToShow">
            <arg name="id" type="i" direction="in"/>
            <arg name="needUpdate" type="b" direction="out"/>
          </method>
          <method name="AboutToShowGroup">
            <arg name="ids" type="ai" direction="in"/>
            <arg name="updatesNeeded" type="ai" direction="out"/>
            <arg name="idErrors" type="ai" direction="out"/>
          </method>
          <signal name="LayoutUpdated"><arg name="revision" type="u"/><arg name="parent" type="i"/></signal>
          <signal name="ItemsPropertiesUpdated">
            <arg name="updatedProps" type="a(ia{sv})"/>
            <arg name="removedProps" type="a(ias)"/>
          </signal>
        </interface>
      </node>
      XML

    # A menu node: the root (id 0) or a separator without *label*, else an
    # item performing *action* or opening *children*.
    private record Node, label : String?, action : Action?, children : Array(Int32)

    private alias Layout = {Int32, Hash(String, Variant), Array(Variant)}

    private METHOD_CALL = ->(_connection : Void*, _sender : UInt8*, _path : UInt8*, interface : UInt8*, method : UInt8*, parameters : Void*, invocation : Void*, data : Void*) do
      notifier = Handles.get(data, StatusNotifier)
      begin
        reply = notifier.call(String.new(interface), String.new(method), Variant.from_raw(parameters))
        C.g_dbus_method_invocation_return_value(invocation, reply.try(&.to_unsafe) || Pointer(Void).null)
      rescue ex
        Log.warn(exception: ex) { "tray: #{String.new(method)} failed" }
        C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", ex.message || ex.class.name)
      end
      nil
    end

    private GET_PROPERTY = ->(_connection : Void*, _sender : UInt8*, _path : UInt8*, interface : UInt8*, property : UInt8*, _error : C::GError**, data : Void*) : Void* do
      value = Handles.get(data, StatusNotifier).property(String.new(interface), String.new(property))
      C.g_variant_ref(value.to_unsafe)
    end

    private APPEARED = ->(_connection : Void*, _name : UInt8*, _owner : UInt8*, data : Void*) do
      Handles.get(data, StatusNotifier).register
      nil
    end

    private VANISHED = ->(_connection : Void*, _name : UInt8*, _data : Void*) { nil }

    @node : Void*
    @vtable = Pointer(C::GDBusInterfaceVTable).malloc(1)
    @registrations = [] of UInt32
    @watch = 0_u32
    @nodes = [] of Node
    @revision = 0_u32

    def initialize(@app : App, @bus : DBus, @tray : Tray)
      @vtable.value.method_call = METHOD_CALL
      @vtable.value.get_property = GET_PROPERTY
      @node = GLibError.check! { |error| C.g_dbus_node_info_new_for_xml(XML, error) }
      rebuild_menu
      export(ITEM_PATH, ITEM)
      export(MENU_PATH, MENU)
      @watch = C.g_bus_watch_name_on_connection(@bus, WATCHER, C::GBusNameWatcherFlags.new(0), APPEARED, VANISHED,
        Handles.retain(self), Handles::RELEASE)
    end

    # Shows *tray*, telling hosts what changed.
    def tray=(tray : Tray) : Tray
      old, @tray = @tray, tray
      emit(ITEM, "NewTitle") if old.title != tray.title
      emit(ITEM, "NewIcon") if old.icon != tray.icon
      emit(ITEM, "NewToolTip") if old.tooltip != tray.tooltip || old.title != tray.title || old.icon != tray.icon
      unless old.menu.same?(tray.menu)
        rebuild_menu
        emit(MENU, "LayoutUpdated", Variant.new({@revision, 0}))
      end
      tray
    end

    # Unexports the item and stops watching for hosts.
    def release : Nil
      C.g_bus_unwatch_name(@watch) unless @watch == 0
      @watch = 0_u32
      @registrations.each { |id| C.g_dbus_connection_unregister_object(@bus, id) }
      @registrations.clear
      C.g_dbus_node_info_unref(@node) unless @node.null?
      @node = Pointer(Void).null
    end

    # Registers the item with the watcher that just appeared.
    protected def register : Nil
      @bus.call(WATCHER, WATCHER_PATH, WATCHER, "RegisterStatusNotifierItem", Variant.new({@bus.unique_name})) do |_reply, error|
        error.try { |ex| Log.warn { "tray: not registered: #{ex.message}" } }
      end
    end

    protected def property(interface : String, name : String) : Variant
      interface == ITEM ? item_property(name) : menu_property(name)
    end

    # Answers *method* of *interface*; `nil` is an empty reply.
    protected def call(interface : String, method : String, args : Variant) : Variant?
      return item_call(method) if interface == ITEM
      case method
      when "GetLayout"
        id, depth, names = args.get(Tuple(Int32, Int32, Array(String)))
        raise ArgumentError.new("no menu item #{id}") unless @nodes[id]?
        Variant.new({@revision, layout(id, depth, names)})
      when "GetGroupProperties"
        ids, names = args.get(Tuple(Array(Int32), Array(String)))
        found = ids.select { |id| @nodes[id]? }
        Variant.new({found.map { |id| {id, properties(id, names)} }})
      when "GetProperty"
        id, name = args.get(Tuple(Int32, String))
        value = properties(id, [name])[name]? || raise ArgumentError.new("no property #{name} on menu item #{id}")
        Variant.new({value})
      when "Event"
        event(args[0].get(Int32), args[1].get(String))
        nil
      when "EventGroup"
        events = args[0]
        errors = (0...events.size).compact_map do |index|
          id = events[index][0].get(Int32)
          @nodes[id]? ? (event(id, events[index][1].get(String)); nil) : id
        end
        Variant.new({errors})
      when "AboutToShow"
        Variant.new({false})
      when "AboutToShowGroup"
        Variant.new({[] of Int32, [] of Int32})
      else
        raise ArgumentError.new("unknown method #{method}")
      end
    end

    private def item_call(method : String) : Variant?
      if method == "Activate"
        @tray.activate.try { |action| perform(action) }
      end
      nil
    end

    private def item_property(name : String) : Variant
      case name
      when "Category"   then Variant.new("ApplicationStatus")
      when "Id"         then Variant.new(@app.id)
      when "Title"      then Variant.new(@tray.title)
      when "Status"     then Variant.new("Active")
      when "WindowId"   then Variant.new(0)
      when "IconName"   then Variant.new(@tray.icon)
      when "ToolTip"    then tooltip
      when "ItemIsMenu" then Variant.new(@tray.activate.nil?)
      when "Menu"       then Variant.new(Variant::ObjectPath.new(MENU_PATH))
      else                   raise ArgumentError.new("unknown property #{name}")
      end
    end

    private def menu_property(name : String) : Variant
      case name
      when "Version"       then Variant.new(3_u32)
      when "TextDirection" then Variant.new("ltr")
      when "Status"        then Variant.new("normal")
      when "IconThemePath" then Variant.new([] of String)
      else                      raise ArgumentError.new("unknown property #{name}")
      end
    end

    # The `(sa(iiay)ss)` tooltip: icon, no pixmaps, title and text.
    private def tooltip : Variant
      # Raw `g_variant_new_tuple`: `Variant` has no `y`, can't build `a(iiay)` items.
      children = StaticArray[
        Variant.new(@tray.icon), Variant.parse("@a(iiay) []"), Variant.new(@tray.title), Variant.new(@tray.tooltip || ""),
      ]
      raw = children.map(&.to_unsafe)
      Variant.take(C.g_variant_ref_sink(C.g_variant_new_tuple(raw.to_unsafe, raw.size)))
    end

    private def event(id : Int32, kind : String) : Nil
      return unless kind == "clicked"
      @nodes[id]?.try(&.action).try { |action| perform(action) }
    end

    private def perform(action : Action) : Nil
      Log.warn { "tray: action #{action.detailed_name} not handled" } unless @app.perform_in(@app.active_window, action)
    end

    private def layout(id : Int32, depth : Int32, names : Array(String)) : Layout
      children = depth == 0 ? [] of Variant : @nodes[id].children.map { |child| Variant.new(layout(child, depth - 1, names)) }
      {id, properties(id, names), children}
    end

    # Returns the dbusmenu properties of node *id* among *names*, all of
    # them when *names* is empty.
    private def properties(id : Int32, names : Array(String)) : Hash(String, Variant)
      node = @nodes[id]
      properties = {} of String => Variant
      if label = node.label
        # dbusmenu reads `_` as mnemonic prefix: escape as `__`.
        properties["label"] = Variant.new(label.gsub('_', "__"))
        properties["children-display"] = Variant.new("submenu") unless node.children.empty?
      elsif id != 0
        properties["type"] = Variant.new("separator")
      end
      properties.select! { |key, _| names.includes?(key) } unless names.empty?
      properties
    end

    private def rebuild_menu : Nil
      @nodes = [Node.new(nil, nil, [] of Int32)]
      @nodes[0] = Node.new(nil, nil, append(@tray.menu))
      @revision += 1
    end

    # Adds the nodes of *menu* and returns the ids of its top level.
    private def append(menu : Menu?) : Array(Int32)
      ids = [] of Int32
      return ids unless menu
      menu.sections.each do |section|
        next if section.empty?
        ids << add(Node.new(nil, nil, [] of Int32)) unless ids.empty?
        section.each do |item|
          ids << case target = item.target
          in Action then add(Node.new(item.label, target, [] of Int32))
          in Menu
            id = add(Node.new(item.label, nil, [] of Int32))
            @nodes[id] = Node.new(item.label, nil, append(target))
            id
          end
        end
      end
      ids
    end

    private def add(node : Node) : Int32
      @nodes << node
      @nodes.size - 1
    end

    private def export(path : String, interface : String) : Nil
      info = C.g_dbus_node_info_lookup_interface(@node, interface)
      @registrations << GLibError.check! do |error|
        C.g_dbus_connection_register_object(@bus, path, info, @vtable, Handles.retain(self), Handles::RELEASE, error)
      end
    end

    private def emit(interface : String, signal : String, args : Variant? = nil) : Nil
      path = interface == ITEM ? ITEM_PATH : MENU_PATH
      @bus.emit(path, interface, signal, args)
    rescue ex : GLibError
      Log.warn { "tray: #{signal} not sent: #{ex.message}" }
    end
  end

  abstract class App
    @tray : Tray?
    @status_notifier : StatusNotifier?

    # Returns the tray icon shown while the application runs.
    getter tray : Tray?

    # Shows *tray* in the desktop's system tray while the application runs,
    # replacing the earlier one; `nil` removes it. Callable from any thread.
    #
    # Desktops show it through a StatusNotifierItem host, such as KDE
    # Plasma's or GNOME's AppIndicator extension; without a host nothing
    # shows.
    def tray=(tray : Tray?) : Tray?
      @tray = tray
      UIThread.dispatch { sync_tray } if running?
      tray
    end

    private def sync_tray : Nil
      tray = @tray || return release_tray
      if notifier = @status_notifier
        notifier.tray = tray
      elsif bus = dbus
        @status_notifier = StatusNotifier.new(self, bus, tray)
      else
        Log.warn { "tray: the application has no session bus connection" }
      end
    end

    private def release_tray : Nil
      @status_notifier.try(&.release)
      @status_notifier = nil
    end
  end
end
