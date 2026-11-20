# src/desktop_kit/window/session.cr
require "json"

module DesktopKit
  # :nodoc:
  # Saves the open windows, their tabs and split layouts to
  # `$XDG_STATE_HOME/<app id>/session.json` and reopens them. A file of
  # another `VERSION`, or one that fails validation, restores nothing.
  module Session
    VERSION = 1

    # A pane of a split tree: a surface with its content's state, or a
    # split holding two panes. *zoomed* marks the tree's zoomed node.
    class Node
      include JSON::Serializable

      getter state : String? = nil
      getter title : String? = nil
      getter? active : Bool = false
      getter? zoomed : Bool = false
      getter layout : SplitTree::Layout? = nil
      getter ratio : Float64? = nil
      getter left : Node? = nil
      getter right : Node? = nil

      def initialize(@state : String?, @title : String?, @active : Bool, @zoomed : Bool)
      end

      def initialize(layout : SplitTree::Layout, ratio : Float64, left : Node, right : Node, @zoomed : Bool)
        @layout = layout
        @ratio = ratio
        @left = left
        @right = right
      end

      def split? : Bool
        !@layout.nil?
      end

      # Whether the node and every node below it is a surface or a split
      # with a ratio strictly between 0 and 1 and both panes.
      def valid? : Bool
        layout, ratio, left, right = @layout, @ratio, @left, @right
        return left.nil? && right.nil? && ratio.nil? if layout.nil?
        return false unless ratio && left && right
        ratio > 0.0 && ratio < 1.0 && left.valid? && right.valid?
      end
    end

    record TabRecord, title : String?, root : Node do
      include JSON::Serializable
    end

    record WindowRecord, width : Int32, height : Int32, maximized : Bool, fullscreen : Bool,
      selected : Int32, tabs : Array(TabRecord) do
      include JSON::Serializable

      def valid? : Bool
        !tabs.empty? && tabs.all?(&.root.valid?)
      end
    end

    record Data, version : Int32, windows : Array(WindowRecord) do
      include JSON::Serializable
    end

    # Returns the session file of *app*.
    def self.path(app : App) : Path
      base = ENV["XDG_STATE_HOME"]?.presence.try { |dir| Path[dir] } || Path.home / ".local" / "state"
      base / app.id / "session.json"
    end

    # Writes the windows of *app*, or removes the file when none is open.
    # Panels are left out.
    def self.save(app : App) : Nil
      file = path(app)
      windows = app.windows.reject { |window| window.closed? || window.panel }.compact_map { |window| record(window) }
      if windows.empty?
        File.delete?(file)
        return
      end
      Dir.mkdir_p(file.parent)
      temp = Path["#{file}.tmp"]
      File.write(temp, Data.new(VERSION, windows).to_json)
      File.rename(temp, file)
    rescue ex : IO::Error | File::Error
      Log.warn { "session not saved: #{ex.message}" }
    end

    # Reopens the saved windows of *app* and returns whether any opened.
    def self.restore(app : App) : Bool
      data = load(path(app)) || return false
      data.windows.each { |record| reopen(app, record) }
      true
    end

    private def self.load(file : Path) : Data?
      return unless File.exists?(file)
      data = Data.from_json(File.read(file))
      return data if data.version == VERSION && !data.windows.empty? && data.windows.all?(&.valid?)
      Log.warn { "session ignored: #{file} holds no valid session" }
      nil
    rescue ex : JSON::ParseException | JSON::SerializableError | IO::Error | File::Error
      Log.warn { "session ignored: #{ex.message}" }
      nil
    end

    private def self.record(window : Window) : WindowRecord?
      tabs = window.tabs
      return if tabs.empty?
      width = height = 0
      C.gtk_window_get_default_size(window.widget, pointerof(width), pointerof(height))
      selected = window.active_tab.try { |tab| tabs.index(tab) } || 0
      records = tabs.map do |tab|
        tree = tab.tree
        TabRecord.new(tab.title_override, node(tree, SplitTree::ROOT, tab.active_surface))
      end
      WindowRecord.new(width, height, window.maximized?, window.fullscreen?, selected, records)
    end

    private def self.node(tree : SplitTree(Surface), handle : Int32, active : Surface?) : Node
      zoomed = tree.zoomed == handle
      case value = tree[handle]
      in Surface
        Node.new(value.content.saved_session_state, value.title_override, value.same?(active), zoomed)
      in SplitTree::Split
        Node.new(value.layout, value.ratio, node(tree, value.left, active), node(tree, value.right, active), zoomed)
      end
    end

    private def self.reopen(app : App, record : WindowRecord) : Nil
      window = app.open_window
      C.gtk_window_set_default_size(window.widget, record.width, record.height) if record.width > 0 && record.height > 0
      tabs = record.tabs.map do |tab_record|
        nodes = [] of Surface | SplitTree::Split
        zoomed = nil.as(Int32?)
        active = nil.as(Surface?)
        flatten(app, tab_record.root, nodes) do |handle, node, surface|
          zoomed = handle if node.zoomed?
          active = surface if surface && node.active?
        end
        tab = Tab.new(app, SplitTree(Surface).new(nodes, zoomed), active)
        tab.title_override = tab_record.title
        window.add_tab(tab, nil)
      end
      tabs[record.selected]?.try { |tab| window.select(tab) }
      window.maximized = true if record.maximized
      window.fullscreen = true if record.fullscreen
      window.present
    end

    # Appends *node* and the nodes below it to *nodes* in preorder, opening
    # a surface for each leaf, and yields each node's handle with its
    # surface. Returns the node's handle.
    private def self.flatten(app : App, node : Node, nodes : Array(Surface | SplitTree::Split), &block : Int32, Node, Surface? ->) : Int32
      handle = nodes.size
      layout, ratio, left, right = node.layout, node.ratio, node.left, node.right
      if layout && ratio && left && right
        nodes << SplitTree::Split.new(layout, ratio, -1, -1)
        block.call(handle, node, nil)
        left_handle = flatten(app, left, nodes, &block)
        right_handle = flatten(app, right, nodes, &block)
        nodes[handle] = SplitTree::Split.new(layout, ratio, left_handle, right_handle)
      else
        surface = app.create_surface(:restore, nil, node.state)
        surface.title_override = node.title
        nodes << surface
        block.call(handle, node, surface)
      end
      handle
    end
  end
end

module DesktopKit
  class App
    # Whether the application saves its windows, tabs and splits when it
    # quits or its last window closes, and reopens them on its first
    # activation instead of calling `#on_activate`.
    #
    # Each surface saves what its content's `Content#session_state`
    # returns; `#new_surface` receives it back with `SurfaceContext::Kind::Restore`.
    # Panels are not saved. When nothing was saved the first activation
    # calls `#on_activate` as usual.
    getter? restore_session : Bool = false

    # :ditto:
    def restore_session=(restore : Bool) : Bool
      @restore_session = restore
    end

    # Set once the session is saved, so the windows quitting closes do not
    # overwrite it; opening a window clears it.
    @session_saved = false

    private def save_session : Nil
      return if @session_saved || !restore_session?
      @session_saved = true
      Session.save(self)
    end
  end
end
