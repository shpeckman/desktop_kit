# src/desktop_kit/window/window_style.cr
module DesktopKit
  # Look of the application's windows and the surfaces in them.
  #
  # ```
  # app.window_style = DesktopKit::WindowStyle.new(
  #   pane_headers: true, cards: true, tabs_in_header: true, pill_tabs: true,
  #   opacity: 0.85, unfocused_opacity: 0.7, gap: 6, tint: "#5a2d2d")
  # ```
  struct WindowStyle
    # Whether each surface shows a header bar with its icon, its title and
    # buttons to split, zoom and close it.
    getter? pane_headers : Bool

    # Whether surfaces show as rounded cards with gaps between them.
    getter? cards : Bool

    # Whether the tab bar sits in the header bar, beside the window title,
    # instead of in a row below it.
    getter? tabs_in_header : Bool

    # Whether windows show a header bar with the title, the tabs and their
    # buttons. Without one, a window has no title bar of its own and tabs
    # change only through actions; libadwaita's own tab keys, such as
    # Ctrl+Tab and Alt+1, reach the content.
    getter? header_bar : Bool

    # Whether tabs show as pills, the selected one outlined, each with its
    # icon on a badge.
    getter? pill_tabs : Bool

    # Returns the opacity of the window background, from 0 to 1.
    getter opacity : Float64

    # Returns the opacity of the surfaces of a split other than the tab's
    # active one, from 0 to 1.
    getter unfocused_opacity : Float64

    # Returns the space around each card, in pixels.
    getter gap : Int32

    # Returns the corner radius of the cards, in pixels.
    getter radius : Int32

    # Returns the color that washes over the window background, fading from
    # its top left corner, as `#rrggbb`.
    getter tint : String?

    # Creates a style; the defaults give GTK's plain look. *gap* and
    # *radius* shape the cards of *cards*, and with them the corners of the
    # windows that draw their own frame.
    #
    # Raises `ArgumentError` when an opacity lies outside 0..1, when *gap* or
    # *radius* is negative or when *tint* is not `#rrggbb`.
    def initialize(*, @pane_headers : Bool = false, @cards : Bool = false, @tabs_in_header : Bool = false,
                   @header_bar : Bool = true, @pill_tabs : Bool = false, @opacity : Float64 = 1.0,
                   @unfocused_opacity : Float64 = 1.0, @gap : Int32 = 4, @radius : Int32 = 12, @tint : String? = nil)
      {opacity: @opacity, unfocused_opacity: @unfocused_opacity}.each do |name, value|
        raise ArgumentError.new("#{name} #{value} outside 0..1") unless 0.0 <= value <= 1.0
      end
      {gap: @gap, radius: @radius}.each do |name, value|
        raise ArgumentError.new("#{name} #{value} is negative") if value < 0
      end
      if (tint = @tint) && !tint.matches?(TINT)
        raise ArgumentError.new("tint #{tint} is not #rrggbb")
      end
    end

    private TINT = /\A#[0-9a-fA-F]{6}\z/

    # A window that draws its own frame and touches no screen edge: the one
    # whose corners follow the cards'.
    private FRAMED = "window.desktop-kit-window.csd" +
                     %w[undecorated maximized fullscreen tiled tiled-top tiled-bottom tiled-left tiled-right].join { |state| ":not(.#{state})" }

    # :nodoc:
    # The style sheet of the options, for windows with the `desktop-kit-window`
    # class; empty for the defaults.
    def to_css : String
      String.build do |css|
        if @opacity < 1.0
          css << "window.desktop-kit-window { background-color: alpha(@window_bg_color, #{@opacity}); }\n"
        end
        if tint = @tint
          css << "window.desktop-kit-window { background-image: linear-gradient(135deg, " \
                 "alpha(#{tint}, 0.4), alpha(#{tint}, 0.1)); }\n"
        end
        if @opacity < 1.0 || @tint
          css << "window.desktop-kit-window headerbar, window.desktop-kit-window tabbar .box, " \
                 "window.desktop-kit-window toolbarview > .top-bar { background: none; box-shadow: none; }\n"
        end
        if @cards
          # A card lies two gaps from the window's edge (its margin and the
          # tab view's): the window's corners are concentric with it.
          css << "window.desktop-kit-window .surface { margin: #{@gap}px; border-radius: #{@radius}px; " \
                 "background-color: alpha(@view_bg_color, #{@opacity}); " \
                 "box-shadow: 0 0 0 1px alpha(@borders, 0.6); }\n"
          css << "window.desktop-kit-window .surface-header { padding: #{@gap // 2}px #{@gap}px #{@gap // 2}px #{@gap + 6}px; }\n"
          css << "window.desktop-kit-window tabview { margin: 0 #{@gap}px #{@gap}px #{@gap}px; }\n"
          css << "window.desktop-kit-window paned > separator { background: none; box-shadow: none; }\n"
          css << FRAMED << " { border-radius: #{@radius + 2 * @gap}px; }\n"
        end
        if @pill_tabs
          css << "window.desktop-kit-window tabbar tabbox > tabboxchild, window.desktop-kit-window tabbar tab " \
                 "{ border-radius: 9999px; }\n"
          # Themes frame the tabs and underline their bar: pills have neither.
          css << "window.desktop-kit-window tabbar .box { border: none; }\n"
          css << "window.desktop-kit-window tabbar tab { padding: 0 6px; border: none; }\n"
          css << "window.desktop-kit-window tabbar tab:selected { background-color: alpha(currentColor, 0.12); " \
                 "box-shadow: inset 0 0 0 1px alpha(currentColor, 0.18); }\n"
          css << "window.desktop-kit-window tabbar tab > image { padding: 3px; border-radius: 6px; " \
                 "background-color: alpha(currentColor, 0.15); }\n"
        end
        if @unfocused_opacity < 1.0
          css << "window.desktop-kit-window .surface:not(.active) { opacity: #{@unfocused_opacity}; }\n"
        end
      end
    end
  end

  abstract class App
    @window_style = WindowStyle.new

    getter window_style : WindowStyle

    # Restyles the windows, the open ones included.
    def window_style=(style : WindowStyle) : WindowStyle
      @window_style = style
      UIThread.dispatch { apply_window_style } if running?
      style
    end

    private def apply_window_style : Nil
      load_runtime_style
      @windows.each(&.apply_style(@window_style))
      @surfaces.each_value(&.apply_style(@window_style))
    end

    # Loads the runtime's own style sheet and that of `#window_style`.
    private def load_runtime_style : Nil
      # Provider ivar is `@runtime_style`: `@style` collided with a spec
      # subclass ivar (subclasses share the ivar namespace).
      C.gtk_css_provider_load_from_string(@runtime_style, Surface::STYLE + Window::STYLE + @window_style.to_css)
    end
  end
end
