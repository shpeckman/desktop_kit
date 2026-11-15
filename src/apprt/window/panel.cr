# src/apprt/window/panel.cr
module Apprt
  # The placement of a panel: a window the desktop docks to a screen edge,
  # shows as the wallpaper or floats above other windows, after kitty's
  # panel kitten.
  #
  # Open one with `App#new_panel` and change it with `Window#panel=`.
  # Panels need a Wayland compositor with the wlr layer shell protocol
  # (`App#panels?`), such as sway, KDE Plasma, Hyprland or niri; GNOME has
  # none.
  #
  # Sizes and margins are logical pixels. *width* applies to `Edge::Left`,
  # `Edge::Right`, `Edge::None` and `Edge::CenterSized`, *height* to
  # `Edge::Top`, `Edge::Bottom`, `Edge::None` and `Edge::CenterSized`; 0
  # takes the content's natural size. A margin applies only on the edges
  # the panel touches.
  #
  # ```
  # # A drop-down quick terminal: 400 pixels tall, above other windows,
  # # focused on click and hidden again when it loses the focus.
  # quick = Apprt::Panel.new(edge: :top, height: 400, layer: :overlay,
  #   focus: :on_demand, hide_on_focus_loss: true, name: "quick")
  # app.new_panel(quick, shown: false)
  # app.bindings = [Apprt::Binding.new("super+grave", Apprt::Action::TogglePanel.new("quick"), global: true)]
  # ```
  record Panel,
    edge : Edge = :top,
    layer : Layer = :bottom,
    width : Int32 = 0,
    height : Int32 = 0,
    margin_top : Int32 = 0,
    margin_right : Int32 = 0,
    margin_bottom : Int32 = 0,
    margin_left : Int32 = 0,
    output : String? = nil,
    focus : Focus = :not_allowed,
    exclusive_zone : Int32? = nil,
    hide_on_focus_loss : Bool = false,
    name : String = "apprt-panel" do
    # Where a panel sits on its monitor.
    enum Edge
      # Along the top edge, spanning the width.
      Top
      # Along the bottom edge, spanning the width.
      Bottom
      # Along the left edge, spanning the height.
      Left
      # Along the right edge, spanning the height.
      Right
      # The whole monitor, below every window, as the wallpaper.
      Background
      # The whole monitor less the margins.
      Center
      # Centered, at its own size; margins have no effect.
      CenterSized
      # In the top left corner, offset by the top and left margins.
      None
    end

    # The stack a panel is drawn in, from the bottom up.
    enum Layer
      Background
      Bottom
      Top
      Overlay
    end

    # When a panel takes the keyboard focus.
    enum Focus
      # Never.
      NotAllowed
      # Always while shown, as the desktop permits.
      Exclusive
      # When the user clicks into it, like other windows.
      OnDemand
    end
  end

  # The `record` macro's block cannot hold private constants for the docs
  # tool.
  struct Panel
    # Layer shell edges in the order of `#margins`.
    private EDGES = {C::GtkLayerShellEdge::Top, C::GtkLayerShellEdge::Right, C::GtkLayerShellEdge::Bottom, C::GtkLayerShellEdge::Left}

    # Anchored edges per `Edge`, indexed like `EDGES`.
    private ANCHORS = {
      Edge::Top         => {true, true, false, true},
      Edge::Bottom      => {false, true, true, true},
      Edge::Left        => {true, false, true, true},
      Edge::Right       => {true, true, true, false},
      Edge::Background  => {true, true, true, true},
      Edge::Center      => {true, true, true, true},
      Edge::CenterSized => {false, false, false, false},
      Edge::None        => {true, false, false, true},
    }

    # Whether *width* and *height* apply per `Edge`.
    private SIZED = {
      Edge::Top         => {false, true},
      Edge::Bottom      => {false, true},
      Edge::Left        => {true, false},
      Edge::Right       => {true, false},
      Edge::Background  => {false, false},
      Edge::Center      => {false, false},
      Edge::CenterSized => {true, true},
      Edge::None        => {true, true},
    }

    private LAYERS = {
      Layer::Background => C::GtkLayerShellLayer::Background,
      Layer::Bottom     => C::GtkLayerShellLayer::Bottom,
      Layer::Top        => C::GtkLayerShellLayer::Top,
      Layer::Overlay    => C::GtkLayerShellLayer::Overlay,
    }

    private FOCUS = {
      Focus::NotAllowed => C::GtkLayerShellKeyboardMode::None,
      Focus::Exclusive  => C::GtkLayerShellKeyboardMode::Exclusive,
      Focus::OnDemand   => C::GtkLayerShellKeyboardMode::OnDemand,
    }

    # Returns the margins as top, right, bottom and left.
    def margins : {Int32, Int32, Int32, Int32}
      {margin_top, margin_right, margin_bottom, margin_left}
    end

    private def effective_layer : Layer
      edge.background? ? Layer::Background : layer
    end

    private def effective_focus : Focus
      hide_on_focus_loss ? Focus::OnDemand : focus
    end

    # Turns *window* into a layer surface; call before it is realized.
    protected def self.init(window : Widget) : Nil
      C.gtk_layer_init_for_window(window)
      # libadwaita windows default to a 360x200 minimum.
      C.gtk_widget_set_size_request(window, 0, 0)
    end

    # Applies the placement to the layer surface *window*.
    protected def apply(window : Widget) : Nil
      C.gtk_layer_set_namespace(window, name)
      C.gtk_layer_set_layer(window, LAYERS[effective_layer])
      C.gtk_layer_set_keyboard_mode(window, FOCUS[effective_focus])
      anchors = ANCHORS[edge]
      EDGES.each_with_index do |side, index|
        C.gtk_layer_set_anchor(window, side, anchors[index] ? 1 : 0)
        C.gtk_layer_set_margin(window, side, margins[index])
      end
      apply_exclusive_zone(window)
      sized_width, sized_height = SIZED[edge]
      C.gtk_window_set_default_size(window, sized_width && width > 0 ? width : -1, sized_height && height > 0 ? height : -1)
      C.gtk_layer_set_monitor(window, Panel.monitor(window, output))
    end

    # Reserves the panel's size on the edges it docks to, unless
    # `#exclusive_zone` overrides it; other edges ignore other panels'
    # zones.
    private def apply_exclusive_zone(window : Widget) : Nil
      if !edge.background? && (zone = exclusive_zone)
        C.gtk_layer_set_exclusive_zone(window, zone)
      elsif edge.top? || edge.bottom? || edge.left? || edge.right?
        C.gtk_layer_auto_exclusive_zone_enable(window)
      else
        C.gtk_layer_set_exclusive_zone(window, -1)
      end
    end

    # Returns the monitor whose connector is *output* on *window*'s
    # display, or null for the compositor's choice.
    protected def self.monitor(window : Widget, output : String?) : Void*
      return Pointer(Void).null unless output
      display = C.gtk_widget_get_display(window)
      each_monitor(display) do |monitor, connector|
        return monitor if connector == output
      end
      Log.warn { "panel output #{output} not found" }
      Pointer(Void).null
    end

    # Returns the connector names of *display*'s monitors.
    protected def self.outputs(display : Void*) : Array(String)
      names = [] of String
      each_monitor(display) { |_monitor, connector| names << connector if connector }
      names
    end

    # Yields each monitor of *display* with its connector name; the monitor
    # is borrowed from the display's list.
    private def self.each_monitor(display : Void*, & : Void*, String? ->) : Nil
      monitors = C.gdk_display_get_monitors(display)
      C.g_list_model_get_n_items(monitors).times do |index|
        monitor = C.g_list_model_get_item(monitors, index)
        C.g_object_unref(monitor)
        yield monitor, Native.string?(C.gdk_monitor_get_connector(monitor))
      end
    end
  end

  class Window
    # Returns the placement of a window opened with `App#new_panel`, or
    # `nil` for an ordinary window.
    getter panel : Panel?

    # Moves and resizes a panel to *panel*. Raises `ArgumentError` when the
    # window was not opened with `App#new_panel`.
    def panel=(panel : Panel) : Panel
      raise ArgumentError.new("not a panel window") unless @panel
      @panel = panel
      panel.apply(@widget)
      panel
    end

    # Hides the panel when it loses the focus and asks to.
    private def panel_focus_changed : Nil
      return unless @panel.try(&.hide_on_focus_loss)
      self.shown = false unless active?
    end
  end

  abstract class App
    # Returns whether the desktop can show panels (`#new_panel`). Raises
    # `RuntimeError` off the GTK thread.
    def panels? : Bool
      UIThread.assert!
      C.gtk_layer_is_supported != 0
    end

    # Returns the names of the monitors, such as `"DP-1"`, for
    # `Panel#output`. Raises `RuntimeError` off the GTK thread.
    def outputs : Array(String)
      UIThread.assert!
      Panel.outputs(C.gdk_display_get_default)
    end

    # Opens a panel placed by *panel* with one tab, presents it unless
    # *shown* is false and returns it. Raises `RuntimeError` off the GTK
    # thread or when the desktop cannot show panels (`#panels?`).
    def new_panel(panel : Panel, shown : Bool = true) : Window
      raise RuntimeError.new("the desktop cannot show panels") unless panels?
      window = open_window(panel)
      window.open_tab(:window, nil)
      window.present if shown
      window
    end

    protected def perform(target : App, action : Action::TogglePanel) : Bool
      panels = @windows.select { |window| window.panel.try(&.name) == action.panel }
      return false if panels.empty?
      shown = panels.none?(&.shown?)
      panels.each { |window| window.shown = shown }
      true
    end
  end
end
